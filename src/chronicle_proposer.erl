%% @author Couchbase <info@couchbase.com>
%% @copyright 2020 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(chronicle_proposer).

-behavior(gen_statem).
-compile(export_all).

-include("chronicle.hrl").

-import(chronicle_utils, [get_position/1]).

-define(SERVER, ?SERVER_NAME(?MODULE)).

%% TODO: move these to the config
-define(ESTABLISH_TERM_TIMEOUT, 10000).
-define(CHECK_PEERS_INTERVAL, 5000).

-record(data, { parent,

                %% TODO: reconsider what's needed and what's not needed here
                history_id,
                term,
                quorum,
                peers,
                machines,
                config,
                config_revision,
                high_seqno,
                committed_seqno,

                peer_statuses,
                monitors_peers,
                monitors_refs,

                %% Used only when the state is 'establish_term'.
                %% TODO: consider using different data records for
                %% establish_term and proposing states
                votes,
                failed_votes,
                branch,

                %% Used when the state is 'proposing'.
                pending_entries,
                pending_high_seqno,
                sync_requests,

                config_change_from,
                postponed_config_requests}).

-record(peer_status, { peer,
                       needs_sync,
                       acked_seqno,
                       acked_commit_seqno,
                       sent_seqno,
                       sent_commit_seqno }).

-record(sync_request, { ref,
                        votes,
                        failed_votes }).

start_link(HistoryId, Term) ->
    Self = self(),
    gen_statem:start_link(?START_NAME(?MODULE),
                          ?MODULE, [Self, HistoryId, Term], []).

sync_quorum(Pid, Ref) ->
    gen_statem:cast(Pid, {sync_quorum, Ref}).

get_config(Pid, Ref) ->
    gen_statem:cast(Pid, {get_config, Ref}).

cas_config(Pid, Ref, NewConfig, Revision) ->
    gen_statem:cast(Pid, {cas_config, Ref, NewConfig, Revision}).

append_commands(Pid, Commands) ->
    gen_statem:cast(Pid, {append_commands, Commands}).

%% gen_statem callbacks
callback_mode() ->
    [handle_event_function, state_enter].

init([Parent, HistoryId, Term]) ->
    chronicle_peers:monitor(),

    PeerStatuses = ets:new(peer_statuses,
                           [protected, set, {keypos, #peer_status.peer}]),
    SyncRequests = ets:new(sync_requests,
                           [protected, set, {keypos, #sync_request.ref}]),
    Data = #data{ parent = Parent,
                  history_id = HistoryId,
                  term = Term,
                  peer_statuses = PeerStatuses,
                  monitors_peers = #{},
                  monitors_refs = #{},
                  %% TODO: store votes, failed_votes and peers as sets
                  votes = [],
                  failed_votes = [],
                  pending_entries = queue:new(),
                  sync_requests = SyncRequests,
                  postponed_config_requests = []},

    {ok, establish_term, Data}.

handle_event(enter, _OldState, NewState, Data) ->
    handle_state_enter(NewState, Data);
handle_event(state_timeout, establish_term_timeout, State, Data) ->
    handle_establish_term_timeout(State, Data);
handle_event(info, check_peers, State, Data) ->
    proposing = State,
    {keep_state, check_peers(Data)};
handle_event(info, {{agent_response, Ref, Peer, Request}, Result}, State,
             #data{peers = Peers} = Data) ->
    case lists:member(Peer, Peers) of
        true ->
            case get_peer_monitor(Peer, Data) of
                {ok, OurRef} when OurRef =:= Ref ->
                    handle_agent_response(Peer, Request, Result, State, Data);
                _ ->
                    ?DEBUG("Ignoring a stale response from peer ~p.~n"
                           "Request:~n~p",
                           [Peer, Request]),
                    keep_state_and_data
            end;
        false ->
            ?INFO("Ignoring a response from a removed peer ~p.~n"
                  "Peers:~n~p~n"
                  "Request:~n~p",
                  [Peer, Peers, Request]),
            keep_state_and_data
    end;
handle_event(info, {nodeup, Peer, Info}, State, Data) ->
    handle_nodeup(Peer, Info, State, Data);
handle_event(info, {nodedown, Peer, Info}, State, Data) ->
    handle_nodedown(Peer, Info, State, Data);
handle_event(info, {'DOWN', MRef, process, Pid, Reason}, State, Data) ->
    handle_down(MRef, Pid, Reason, State, Data);
handle_event(cast, _Request, establish_term, _Data) ->
    %% Postpone till state is proposing.
    {keep_state_and_data, postpone};
handle_event(cast, {sync_quorum, Ref}, proposing, Data) ->
    handle_sync_quorum(Ref, Data);
handle_event(cast, {get_config, Ref} = Request, proposing, Data) ->
    maybe_postpone_config_request(
      Request, Data,
      fun () ->
              handle_get_config(Ref, Data)
      end);
handle_event(cast,
             {cas_config, Ref, NewConfig, Revision} = Request,
             proposing, Data) ->
    maybe_postpone_config_request(
      Request, Data,
      fun () ->
              handle_cas_config(Ref, NewConfig, Revision, Data)
      end);
handle_event(cast, {append_commands, Commands}, proposing, Data) ->
    handle_append_commands(Commands, Data);
handle_event({call, From}, _Call, _State, _Data) ->
    {keep_state_and_data, [{reply, From, nack}]};
handle_event(Type, Event, _State, _Data) ->
    ?WARNING("Unexpected event ~p", [{Type, Event}]),
    keep_state_and_data.

%% internal
handle_state_enter(establish_term,
                   #data{history_id = HistoryId, term = Term} = Data) ->
    %% Establish term locally first. This ensures that the metadata we're
    %% going to be using won't change (unless another nodes starts a higher
    %% term) between when we get it here and when we get a majority of votes.
    case chronicle_agent:establish_local_term(HistoryId, Term) of
        {ok, Metadata} ->
            Peers = get_establish_peers(Metadata),
            Quorum = get_establish_quorum(Metadata),
            LivePeers = chronicle_peers:get_live_peers(Peers),
            DeadPeers = Peers -- LivePeers,

            ?DEBUG("Going to establish term ~p (history id ~p).~n"
                   "Metadata:~n~p~n"
                   "Live peers:~n~p",
                   [Term, HistoryId, Metadata, LivePeers]),

            #metadata{config = Config,
                      config_revision = ConfigRevision,
                      high_seqno = HighSeqno,
                      committed_seqno = CommittedSeqno,
                      pending_branch = PendingBranch} = Metadata,

            case is_quorum_feasible(Peers, DeadPeers, Quorum) of
                true ->
                    OtherPeers = LivePeers -- [?PEER()],

                    %% Send a fake response to update our state with the
                    %% knowledge that we've established the term
                    %% locally. Initally, I wasn't planning to use such
                    %% somewhat questionable approach and instead would update
                    %% the state here. But if our local peer is the only peer,
                    %% then we need to transition to propsing state
                    %% immediately. But brain-dead gen_statem won't let you
                    %% transition to a different state from a state_enter
                    %% callback. So here we are.
                    NewData0 = send_local_establish_term(Metadata, Data),
                    NewData1 =
                        send_establish_term(OtherPeers, Metadata, NewData0),
                    NewData = NewData1#data{peers = Peers,
                                            quorum = Quorum,
                                            machines = config_machines(Config),
                                            votes = [],
                                            failed_votes = DeadPeers,
                                            config = Config,
                                            config_revision = ConfigRevision,
                                            high_seqno = HighSeqno,
                                            pending_high_seqno = HighSeqno,
                                            committed_seqno = CommittedSeqno,
                                            branch = PendingBranch},
                    {keep_state,
                     NewData,
                     {state_timeout,
                      ?ESTABLISH_TERM_TIMEOUT, establish_term_timeout}};
                false ->
                    %% This should be a rare situation. That's because to be
                    %% elected a leader we need to get a quorum of votes. So
                    %% at least a quorum of nodes should be alive.
                    ?WARNING("Can't establish term ~p, history id ~p.~n"
                             "Not enough peers are alive to achieve quorum.~n"
                             "Peers: ~p~n"
                             "Live peers: ~p~n"
                             "Quorum: ~p",
                             [Term, HistoryId, Peers, LivePeers, Quorum]),
                    {stop, {error, no_quorum}}
            end;
        {error, Error} ->
            ?DEBUG("Error trying to establish local term. Stepping down.~n"
                   "History id: ~p~n"
                   "Term: ~p~n"
                   "Error: ~p",
                   [HistoryId, Term, Error]),
            {stop, {local_establish_term_failed, HistoryId, Term, Error}}
    end;
handle_state_enter(proposing, #data{parent = Parent,
                                    history_id = HistoryId,
                                    term = Term,
                                    high_seqno = HighSeqno} = Data) ->
    chronicle_server:proposer_ready(Parent, HistoryId, Term, HighSeqno),

    NewData0 = maybe_resolve_branch(Data),
    NewData = maybe_complete_config_transition(NewData0),
    {keep_state, replicate(check_peers(NewData))}.

handle_establish_term_timeout(establish_term = _State, #data{term = Term}) ->
    ?ERROR("Failed to establish term ~p after ~bms",
           [Term, ?ESTABLISH_TERM_TIMEOUT]),
    {stop, establish_term_timeout}.

check_peers(#data{peers = Peers} = Data) ->
    LivePeers = chronicle_peers:get_live_peers(Peers),
    MonitoredPeers = get_monitored_peers(Data),
    PeersToCheck = LivePeers -- MonitoredPeers,

    erlang:send_after(?CHECK_PEERS_INTERVAL, self(), check_peers),
    send_request_position(PeersToCheck, Data).

handle_agent_response(Peer,
                      {establish_term, _, _, _} = Request,
                      Result, State, Data) ->
    handle_establish_term_result(Peer, Request, Result, State, Data);
handle_agent_response(Peer,
                      {append, _, _, _, _} = Request,
                      Result, State, Data) ->
    handle_append_result(Peer, Request, Result, State, Data);
handle_agent_response(Peer, peer_position, Result, State, Data) ->
    handle_peer_position_result(Peer, Result, State, Data);
handle_agent_response(Peer,
                      {sync_quorum, _} = Request,
                      Result, State, Data) ->
    handle_sync_quorum_result(Peer, Request, Result, State, Data).

handle_establish_term_result(Peer,
                             {establish_term, HistoryId, Term, Position},
                             Result, State, Data) ->
    true = (HistoryId =:= Data#data.history_id),
    true = (Term =:= Data#data.term),

    case Result of
        {ok, #metadata{committed_seqno = CommittedSeqno} = Metadata} ->
            init_peer_status(Peer, Metadata, Data),
            establish_term_handle_vote(Peer, {ok, CommittedSeqno}, State, Data);
        {error, Error} ->
            case handle_common_error(Peer, Error, Data) of
                {stop, _} = Stop ->
                    Stop;
                ignored ->
                    ?WARNING("Failed to establish "
                             "term ~p (history id ~p, log position ~p) "
                             "on peer ~p: ~p",
                             [Term, HistoryId, Position, Peer, Error]),

                    case Error of
                        {behind, _} ->
                            %% We keep going desbite the fact we're behind
                            %% this peer because we still might be able to get
                            %% a majority of votes.
                            establish_term_handle_vote(Peer,
                                                       failed, State, Data);
                        _ ->
                            {stop, {unexpected_error, Peer, Error}}
                    end
            end
    end.

handle_common_error(Peer, Error,
                    #data{history_id = HistoryId, term = Term}) ->
    case Error of
        {conflicting_term, OtherTerm} ->
            ?INFO("Saw term conflict when trying on peer ~p.~n"
                  "History id: ~p~n"
                  "Our term: ~p~n"
                  "Conflicting term: ~p",
                  [Peer, HistoryId, Term, OtherTerm]),
            {stop, {conflicting_term, Term, OtherTerm}};
        {history_mismatch, OtherHistoryId} ->
            ?INFO("Saw history mismatch when trying on peer ~p.~n"
                  "Our history id: ~p~n"
                  "Conflicting history id: ~n",
                  [Peer, HistoryId, OtherHistoryId]),

            %% The system has undergone a partition. Either we are part of the
            %% new partition but haven't received the corresponding branch
            %% record yet. Or alternatively, we've been partitioned out. In
            %% the latter case we, probably, shouldn't continue to operate.
            %%
            %% TODO: handle the latter case better
            {stop, {history_mismatch, HistoryId, OtherHistoryId}};
        _ ->
            ignored
    end.

establish_term_handle_vote(_Peer, _Status, proposing, Data) ->
    %% We'are already proposing. So nothing needs to be done.
    {keep_state, Data};
establish_term_handle_vote(Peer, Status, establish_term,
                           #data{high_seqno = HighSeqno,
                                 committed_seqno = OurCommittedSeqno,
                                 votes = Votes,
                                 failed_votes = FailedVotes} = Data) ->
    NewData =
        case Status of
            {ok, CommittedSeqno} ->
                NewCommittedSeqno = max(OurCommittedSeqno, CommittedSeqno),
                case NewCommittedSeqno =/= OurCommittedSeqno of
                    true ->
                        true = (HighSeqno >= NewCommittedSeqno),
                        ?INFO("Discovered new committed seqno from peer ~p.~n"
                              "Old committed seqno: ~p~n"
                              "New committed seqno: ~p",
                              [Peer, OurCommittedSeqno, NewCommittedSeqno]);
                    false ->
                        ok
                end,

                Data#data{votes = [Peer | Votes],
                          committed_seqno = NewCommittedSeqno};
            failed ->
                Data#data{failed_votes = [Peer | FailedVotes]}
        end,

    establish_term_maybe_transition(NewData).

establish_term_maybe_transition(#data{term = Term,
                                      history_id = HistoryId,
                                      peers = Peers,
                                      votes = Votes,
                                      failed_votes = FailedVotes,
                                      quorum = Quorum} = Data) ->
    case have_quorum(Votes, Quorum) of
        true ->
            ?DEBUG("Established term ~p (history id ~p) successfully.~n"
                   "Votes: ~p~n",
                   [Term, HistoryId, Votes]),

            {next_state, proposing, Data};
        false ->
            case is_quorum_feasible(Peers, FailedVotes, Quorum) of
                true ->
                    {keep_state, Data};
                false ->
                    ?WARNING("Couldn't establish term ~p, history id ~p.~n"
                             "Votes received: ~p~n"
                             "Quorum: ~p~n",
                             [Term, HistoryId, Votes, Quorum]),
                    {stop, {error, no_quorum}}
            end
    end.

maybe_resolve_branch(#data{branch = undefined} = Data) ->
    Data;
maybe_resolve_branch(#data{high_seqno = HighSeqno,
                           committed_seqno = CommittedSeqno,
                           branch = Branch,
                           config = Config} = Data) ->
    NewData = Data#data{branch = undefined,
                        %% Note, that this essintially truncates any
                        %% uncommitted entries. This is acceptable/safe to do
                        %% for the following reasons:
                        %%
                        %%  1. We are going through a quorum failover, so data
                        %%  inconsistencies are expected.
                        %%
                        %%  2. Since a unanimous quorum is required for
                        %%  resolving quorum failovers, the leader is
                        %%  guaranteed to know the highest committed seqno
                        %%  observed by the surviving part of the cluster. In
                        %%  other words, we won't truncate something that was
                        %%  known to have been committed.
                        high_seqno = CommittedSeqno,
                        pending_high_seqno = CommittedSeqno},

    %% Note, that the new config may be based on an uncommitted config that
    %% will get truncated from the history. This can be confusing and it's
    %% possible to deal with this situation better. But for the time being I
    %% decided not to bother.
    NewConfig = Config#config{voters = Branch#branch.peers},

    ?INFO("Resolving a branch.~n"
          "High seqno: ~p~n"
          "Committed seqno: ~p~n"
          "Branch:~n~p~n"
          "Latest known config:~n~p~n"
          "New config:~n~p",
          [HighSeqno, CommittedSeqno, Branch, Config, NewConfig]),

    force_propose_config(NewConfig, NewData).

handle_append_result(Peer, Request, Result, proposing, Data) ->
    {append, HistoryId, Term, CommittedSeqno, HighSeqno} = Request,

    true = (HistoryId =:= Data#data.history_id),
    true = (Term =:= Data#data.term),

    case Result of
        ok ->
            handle_append_ok(Peer, HighSeqno, CommittedSeqno, Data);
        {error, Error} ->
            handle_append_error(Peer, Error, Data)
    end.

handle_append_error(Peer, Error, Data) ->
    case handle_common_error(Peer, Error, Data) of
        {stop, _} = Stop ->
            Stop;
        ignored ->
            case Error of
                {missing_entries, Metadata} ->
                    reset_peer_status(Peer, Metadata, Data),
                    {keep_state, replicate(Data)};
                _ ->
                    ?WARNING("Append failed on peer ~p: ~p", [Peer, Error]),
                    {stop, {unexpected_error, Peer, Error}}
            end
    end.

handle_append_ok(Peer, PeerHighSeqno, PeerCommittedSeqno,
                 #data{committed_seqno = CommittedSeqno,
                       pending_entries = PendingEntries} = Data) ->
    ?DEBUG("Append ok on peer ~p.~n"
           "High Seqno: ~p~n"
           "Committed Seqno: ~p",
           [Peer, PeerHighSeqno, PeerCommittedSeqno]),
    set_peer_acked_seqnos(Peer, PeerHighSeqno, PeerCommittedSeqno, Data),

    case deduce_committed_seqno(Data) of
        {ok, NewCommittedSeqno}
          when NewCommittedSeqno > CommittedSeqno ->
            ?DEBUG("Committed seqno advanced.~n"
                   "New committed seqno: ~p~n"
                   "Old committed seqno: ~p",
                   [NewCommittedSeqno, CommittedSeqno]),
            NewPendingEntries =
                queue_dropwhile(
                  fun (Entry) ->
                          Entry#log_entry.seqno =< NewCommittedSeqno
                  end, PendingEntries),

            NewData0 = Data#data{committed_seqno = NewCommittedSeqno,
                                 high_seqno = NewCommittedSeqno,
                                 pending_entries = NewPendingEntries},

            {NewData, Effects} = handle_pending_config_requests(NewData0),
            {keep_state, replicate(NewData), Effects};
        {ok, _NewCommittedSeqno} ->
            %% Note, that it's possible for the deduced committed seqno to go
            %% backwards with respect to our own committed seqno here. This
            %% may happen for multiple reasons. The simplest scenario is where
            %% some nodes go down at which point their peer statuses are
            %% erased. If the previous committed seqno was acknowledged only
            %% by a minimal majority of nodes, any of them going down will
            %% result in the deduced seqno going backwards.
            keep_state_and_data;
        no_quorum ->
            %% This case is possible because deduce_committed_seqno/1 always
            %% uses the most up-to-date config. So what was committed in the
            %% old config, might not yet have a quorum in the current
            %% configuration.
            keep_state_and_data
    end.

handle_peer_position_result(Peer, Result, proposing, Data) ->
    ?DEBUG("Peer position response from ~p:~n~p", [Peer, Result]),

    case Result of
        {ok, Metadata} ->
            init_peer_status(Peer, Metadata, Data),
            {keep_state, replicate(Data)};
        {error, Error} ->
            {stop, _} = handle_common_error(Peer, Error, Data)
    end.

handle_sync_quorum_result(Peer, {sync_quorum, Ref}, Result, proposing,
                          #data{sync_requests = SyncRequests} = Data) ->
    ?DEBUG("Sync quorum response from ~p: ~p", [Peer, Result]),
    case ets:lookup(SyncRequests, Ref) of
        [] ->
            keep_state_and_data;
        [#sync_request{} = Request] ->
            case Result of
                {ok, _} ->
                    sync_quorum_handle_vote(Peer, ok, Request, Data),
                    keep_state_and_data;
                {error, Error} ->
                    case handle_common_error(Peer, Error, Data) of
                        {stop, _} = Stop ->
                            Stop;
                        ignored ->
                            ?ERROR("Unexpected error in sync quorum: ~p",
                                   [Error]),
                            sync_quorum_handle_vote(Peer,
                                                    failed, Request, Data),
                            keep_state_and_data
                    end
            end
    end.

sync_quorum_handle_vote(Peer, Status,
                        #sync_request{ref = Ref,
                                      votes = Votes,
                                      failed_votes = FailedVotes} = Request,
                        #data{sync_requests = Requests} = Data) ->
    NewRequest =
        case Status of
            ok ->
                Request#sync_request{votes = [Peer | Votes]};
            failed ->
                Request#sync_request{failed_votes = [Peer | FailedVotes]}
        end,

    case sync_quorum_maybe_reply(NewRequest, Data) of
        continue ->
            ets:insert(Requests, NewRequest);
        done ->
            ets:delete(Requests, Ref)
    end.

sync_quorum_maybe_reply(Request, Data) ->
    case sync_quorum_check_result(Request, Data) of
        continue ->
            continue;
        Result ->
            reply_request(Request#sync_request.ref, Result, Data),
            done
    end.

sync_quorum_check_result(#sync_request{votes = Votes,
                                       failed_votes = FailedVotes},
                         #data{quorum = Quorum, peers = Peers}) ->
    case have_quorum(Votes, Quorum) of
        true ->
            ok;
        false ->
            case is_quorum_feasible(Peers, FailedVotes, Quorum) of
                true ->
                    continue;
                false ->
                    {error, no_quorum}
            end
    end.

sync_quorum_handle_peer_down(Peer, #data{sync_requests = Tab} = Data) ->
    lists:foreach(
      fun (#sync_request{votes = Votes,
                         failed_votes = FailedVotes} = Request) ->
              HasVoted = lists:member(Peer, Votes)
                  orelse lists:member(Peer, FailedVotes),

              case HasVoted of
                  true ->
                      ok;
                  false ->
                      sync_quorum_handle_vote(Peer, failed, Request, Data)
              end
      end, ets:tab2list(Tab)).

sync_quorum_on_config_update(AddedPeers, #data{sync_requests = Tab} = Data) ->
    lists:foldl(
      fun (#sync_request{ref = Ref} = Request, AccData) ->
              %% We might have a quorum in the new configuration. If that's
              %% the case, reply to the request immediately.
              case sync_quorum_maybe_reply(Request, AccData) of
                  done ->
                      ets:delete(Tab, Ref),
                      AccData;
                  continue ->
                      %% If there are new peers, we need to send extra
                      %% ensure_term requests to them. Otherwise, we might not
                      %% ever get enough responses to reach quorum.
                      send_ensure_term(AddedPeers, {sync_quorum, Ref}, AccData)
              end
      end, Data, ets:tab2list(Tab)).

maybe_complete_config_transition(#data{config = Config} = Data) ->
    case Config of
        #config{} ->
            Data;
        #transition{future_config = FutureConfig} ->
            case is_config_committed(Data) of
                true ->
                    %% Preserve config_change_from if any.
                    From = Data#data.config_change_from,
                    propose_config(FutureConfig, From, Data);
                false ->
                    Data
            end
    end.

maybe_reply_config_change(#data{config_change_from = From} = Data) ->
    case is_config_committed(Data) andalso From =/= undefined of
        true ->
            Revision = Data#data.config_revision,
            reply_request(From, {ok, Revision}, Data),
            Data#data{config_change_from = undefined};
        false ->
            Data
    end.

maybe_postpone_config_request(Request, Data, Fun) ->
    case is_config_committed(Data) of
        true ->
            Fun();
        false ->
            #data{postponed_config_requests = Postponed} = Data,
            NewPostponed = [{cast, Request} | Postponed],
            {keep_state, Data#data{postponed_config_requests = NewPostponed}}
    end.

handle_pending_config_requests(Data) ->
    NewData0 = maybe_complete_config_transition(Data),
    NewData1 = maybe_reply_config_change(NewData0),

    #data{postponed_config_requests = Postponed} = NewData1,
    case is_config_committed(NewData1) andalso Postponed =/= [] of
        true ->
            %% Deliver postponed config changes again. We've postponed them
            %% all the way till this moment to be able to return an error that
            %% includes the revision of the conflicting config. That way the
            %% caller can wait to receive the conflicting config before
            %% retrying.
            NewData2 = NewData1#data{postponed_config_requests = []},
            Effects = [{next_event, Type, Request} ||
                          {Type, Request} <- lists:reverse(Postponed)],
            {NewData2, Effects};
        false ->
            {NewData1, []}
    end.

is_config_committed(#data{config_revision = {_, _, ConfigSeqno},
                          committed_seqno = CommittedSeqno}) ->
    ConfigSeqno =< CommittedSeqno.

replicate(Data) ->
    #data{committed_seqno = CommittedSeqno,
          pending_high_seqno = HighSeqno} = Data,

    case get_peers_to_replicate(HighSeqno, CommittedSeqno, Data) of
        [] ->
            Data;
        Peers ->
            send_append(Peers, Data)
    end.

get_peers_to_replicate(HighSeqno, CommitSeqno, #data{peers = Peers} = Data) ->
    LivePeers = chronicle_peers:get_live_peers(Peers),

    lists:filtermap(
      fun (Peer) ->
              case get_peer_status(Peer, Data) of
                  {ok, #peer_status{needs_sync = NeedsSync,
                                    sent_seqno = PeerSentSeqno,
                                    sent_commit_seqno = PeerSentCommitSeqno}} ->
                      DoSync =
                          NeedsSync
                          orelse HighSeqno > PeerSentSeqno
                          orelse CommitSeqno > PeerSentCommitSeqno,

                      case DoSync of
                          true ->
                              {true, {Peer, PeerSentSeqno}};
                          false ->
                              false
                      end;
                  not_found ->
                      false
              end
      end, LivePeers).

config_peers(#config{voters = Voters}) ->
    Voters;
config_peers(#transition{current_config = Current,
                         future_config = Future}) ->
    lists:usort(config_peers(Current) ++ config_peers(Future)).

config_machines(#config{state_machines = Machines}) ->
    maps:keys(Machines);
config_machines(#transition{future_config = FutureConfig}) ->
    config_machines(FutureConfig).

get_quorum(Config) ->
    {joint,
     %% Include local agent in all quorums.
     {all, sets:from_list([?PEER()])},
     do_get_quorum(Config)}.

do_get_quorum(#config{voters = Voters}) ->
    {majority, sets:from_list(Voters)};
do_get_quorum(#transition{current_config = Current, future_config = Future}) ->
    {joint, do_get_quorum(Current), do_get_quorum(Future)}.

get_quorum_peers(Quorum) ->
    sets:to_list(do_get_quorum_peers(Quorum)).

do_get_quorum_peers({majority, Peers}) ->
    Peers;
do_get_quorum_peers({all, Peers}) ->
    Peers;
do_get_quorum_peers({joint, Quorum1, Quorum2}) ->
    sets:union(do_get_quorum_peers(Quorum1),
               do_get_quorum_peers(Quorum2)).

have_quorum(AllVotes, Quorum)
  when is_list(AllVotes) ->
    do_have_quorum(sets:from_list(AllVotes), Quorum);
have_quorum(AllVotes, Quorum) ->
    do_have_quorum(AllVotes, Quorum).

do_have_quorum(AllVotes, {joint, Quorum1, Quorum2}) ->
    do_have_quorum(AllVotes, Quorum1) andalso do_have_quorum(AllVotes, Quorum2);
do_have_quorum(AllVotes, {all, QuorumNodes}) ->
    MissingVotes = sets:subtract(QuorumNodes, AllVotes),
    sets:size(MissingVotes) =:= 0;
do_have_quorum(AllVotes, {majority, QuorumNodes}) ->
    Votes = sets:intersection(AllVotes, QuorumNodes),
    sets:size(Votes) * 2 > sets:size(QuorumNodes).

is_quorum_feasible(Peers, FailedVotes, Quorum) ->
    PossibleVotes = Peers -- FailedVotes,
    have_quorum(PossibleVotes, Quorum).

%% TODO: find a better place for the following functions
get_establish_quorum(Metadata) ->
    case Metadata#metadata.pending_branch of
        undefined ->
            get_quorum(Metadata#metadata.config);
        #branch{peers = BranchPeers} ->
            {all, sets:from_list(BranchPeers)}
    end.

get_establish_peers(Metadata) ->
    get_quorum_peers(get_establish_quorum(Metadata)).

handle_nodeup(Peer, _Info, State, #data{peers = Peers} = Data) ->
    ?INFO("Peer ~p came up", [Peer]),
    case State of
        establish_term ->
            %% Note, no attempt is made to send establish_term requests to
            %% peers that come up while we're in establish_term state. The
            %% motivation is as follows:
            %%
            %%  1. We go through this state only once right after an election,
            %%  so normally there should be a quorum of peers available anyway.
            %%
            %%  2. Since peers can flip back and forth, it's possible that
            %%  we've already sent an establish_term request to this peer and
            %%  we'll get an error when we try to do this again.
            %%
            %%  3. In the worst case, we won't be able to establish the
            %%  term. This will trigger another election and once and if we're
            %%  elected again, we'll retry with a new set of live peers.
            keep_state_and_data;
        proposing ->
            case lists:member(Peer, Peers) of
                true ->
                    {keep_state, send_request_peer_position(Peer, Data)};
                false ->
                    ?INFO("Peer ~p is not in peers:~n~p", [Peer, Peers]),
                    keep_state_and_data
            end
    end.

handle_nodedown(Peer, Info, _State, _Data) ->
    %% If there was an outstanding request, we'll also receive a DOWN message
    %% and handle everything there. Otherwise, we don't care.
    ?INFO("Peer ~p went down: ~p", [Peer, Info]),
    keep_state_and_data.

handle_down(MRef, Pid, Reason, State, Data) ->
    {ok, Peer, NewData} = take_monitor(MRef, Data),
    ?INFO("Observed agent ~p on peer ~p "
          "go down with reason ~p", [Pid, Peer, Reason]),

    case Peer =:= ?PEER() of
        true ->
            ?ERROR("Terminating proposer because local "
                   "agent ~p terminated with reason ~p",
                   [Pid, Reason]),
            {stop, {agent_terminated, Reason}};
        false ->
            case State of
                establish_term ->
                    establish_term_handle_vote(Peer, failed, State, NewData);
                proposing ->
                    remove_peer_status(Peer, NewData),
                    {keep_state, NewData}
            end
    end.

handle_append_commands(Commands,
                       #data{pending_high_seqno = PendingHighSeqno,
                             pending_entries = PendingEntries} = Data) ->
    {NewPendingHighSeqno, NewPendingEntries, NewData0} =
        lists:foldl(
          fun (Command, {PrevSeqno, AccEntries, AccData} = Acc) ->
                  Seqno = PrevSeqno + 1,
                  case handle_command(Command, Seqno, AccData) of
                      {ok, LogEntry, NewAccData} ->
                          {Seqno, queue:in(LogEntry, AccEntries), NewAccData};
                      ignore ->
                          Acc
                  end
          end,
          {PendingHighSeqno, PendingEntries, Data}, Commands),

    NewData1 = NewData0#data{pending_entries = NewPendingEntries,
                             pending_high_seqno = NewPendingHighSeqno},

    {keep_state, replicate(NewData1)}.

handle_command({rsm_command, RSMName, CommandId, Command}, Seqno,
               #data{machines = Machines} = Data) ->
    case lists:member(RSMName, Machines) of
        true ->
            RSMCommand = #rsm_command{rsm_name = RSMName,
                                      id = CommandId,
                                      command = Command},
            {ok, make_log_entry(Seqno, RSMCommand, Data), Data};
        false ->
            ?WARNING("Received a command "
                     "referencing a non-existing RSM: ~p", [RSMName]),
            ignore
    end.

handle_sync_quorum(Ref, #data{peers = Peers,
                              sync_requests = SyncRequests} = Data) ->
    %% TODO: timeouts
    LivePeers = chronicle_peers:get_live_peers(Peers),
    DeadPeers = Peers -- LivePeers,

    Request = #sync_request{ref = Ref, votes = [], failed_votes = DeadPeers},
    case sync_quorum_maybe_reply(Request, Data) of
        continue ->
            ets:insert_new(SyncRequests, Request),
            {keep_state, send_ensure_term(LivePeers, {sync_quorum, Ref}, Data)};
        done ->
            keep_state_and_data
    end.

%% TODO: make the value returned fully linearizable?
handle_get_config(Ref, #data{config = Config,
                             config_revision = Revision} = Data) ->
    true = is_config_committed(Data),
    #config{} = Config,
    reply_request(Ref, {ok, Config, Revision}, Data),
    keep_state_and_data.

handle_cas_config(Ref, NewConfig, CasRevision,
                  #data{config = Config,
                        config_revision = ConfigRevision} = Data) ->
    %% TODO: this protects against the client proposing transition. But in
    %% reality, it should be solved in some other way
    #config{} = NewConfig,
    #config{} = Config,
    case CasRevision =:= ConfigRevision of
        true ->
            %% TODO: need to backfill new nodes
            Transition = #transition{current_config = Config,
                                     future_config = NewConfig},
            NewData = propose_config(Transition, Ref, Data),
            {keep_state, replicate(NewData)};
        false ->
            Reply = {error, {cas_failed, ConfigRevision}},
            reply_request(Ref, Reply, Data),
            keep_state_and_data
    end.

make_log_entry(Seqno, Value, #data{history_id = HistoryId, term = Term}) ->
    #log_entry{history_id = HistoryId,
               term = Term,
               seqno = Seqno,
               value = Value}.

update_config(Config, Revision, Data) ->
    Quorum = get_quorum(Config),
    NewPeers = get_quorum_peers(Quorum),
    NewData = Data#data{config = Config,
                        config_revision = Revision,
                        peers = NewPeers,
                        quorum = Quorum,
                        machines = config_machines(Config)},

    OldPeers = Data#data.peers,

    RemovedPeers = OldPeers -- NewPeers,
    AddedPeers = NewPeers -- OldPeers,

    handle_added_peers(AddedPeers, handle_removed_peers(RemovedPeers, NewData)).

handle_removed_peers(Peers, Data) ->
    remove_peer_statuses(Peers, Data),
    demonitor_agents(Peers, Data).

handle_added_peers(Peers, Data) ->
    NewData = check_peers(Data),
    sync_quorum_on_config_update(Peers, NewData).

log_entry_revision(#log_entry{history_id = HistoryId,
                              term = Term, seqno = Seqno}) ->
    {HistoryId, Term, Seqno}.

force_propose_config(Config, #data{config_change_from = undefined} = Data) ->
    %% This function doesn't check that the current config is committed, which
    %% should be the case for regular config transitions. It's only meant to
    %% be used after resolving a branch.
    do_propose_config(Config, undefined, Data).

propose_config(Config, From, Data) ->
    true = is_config_committed(Data),
    do_propose_config(Config, From, Data).

%% TODO: right now when this function is called we replicate the proposal in
%% its own batch. But it can be coalesced with user batches.
do_propose_config(Config, From, #data{pending_high_seqno = HighSeqno,
                                      pending_entries = Entries} = Data) ->
    Seqno = HighSeqno + 1,
    LogEntry = make_log_entry(Seqno, Config, Data),
    Revision = log_entry_revision(LogEntry),

    NewEntries = queue:in(LogEntry, Entries),
    NewData = Data#data{pending_entries = NewEntries,
                        pending_high_seqno = Seqno,
                        config_change_from = From},
    update_config(Config, Revision, NewData).

get_peer_status(Peer, #data{peer_statuses = Tab}) ->
    case ets:lookup(Tab, Peer) of
        [#peer_status{} = PeerStatus] ->
            {ok, PeerStatus};
        [] ->
            not_found
    end.

update_peer_status(Peer, Fun, #data{peer_statuses = Tab} = Data) ->
    {ok, PeerStatus} = get_peer_status(Peer, Data),
    ets:insert(Tab, Fun(PeerStatus)).

reset_peer_status(Peer, Metadata, Data) ->
    remove_peer_status(Peer, Data),
    init_peer_status(Peer, Metadata, Data).

init_peer_status(Peer, Metadata, #data{term = OurTerm,
                                       peer_statuses = Tab}) ->
    #metadata{term_voted = PeerTermVoted,
              committed_seqno = PeerCommittedSeqno,
              high_seqno = PeerHighSeqno} = Metadata,

    {CommittedSeqno, HighSeqno, NeedsSync} =
        case PeerTermVoted =:= OurTerm of
            true ->
                %% We've lost communication with the peer. But it's already
                %% voted in our current term, so our histories are compatible.
                {PeerCommittedSeqno, PeerHighSeqno, false};
            false ->
                %% Peer has some uncommitted entries that need to be
                %% truncated. Normally, that'll just happen in the course of
                %% normal replication, but if there are no mutations to
                %% replicate, we need to force replicate to the node.
                DoSync = PeerHighSeqno > PeerCommittedSeqno,


                %% The peer hasn't voted in our term yet, so it may have
                %% divergent entries in the log that need to be truncated.
                %%
                %% TODO: We set all seqno-s to peer's committed seqno. That is
                %% because entries past peer's committed seqno may come from
                %% an alternative, never-to-be-committed history. Using
                %% committed seqno is always safe, but that also means that we
                %% might need to needlessly resend some of the entries that
                %% the peer already has.
                %%
                %% Somewhat peculiarly, the same logic also applies to our
                %% local agent. This all can be addressed by including more
                %% information into establish_term() response and append()
                %% call. But I'll leave for later.
                {PeerCommittedSeqno, PeerCommittedSeqno, DoSync}
        end,

    true = ets:insert_new(Tab,
                          #peer_status{peer = Peer,
                                       needs_sync = NeedsSync,
                                       acked_seqno = HighSeqno,
                                       sent_seqno = HighSeqno,
                                       acked_commit_seqno = CommittedSeqno,
                                       sent_commit_seqno = CommittedSeqno}).

set_peer_sent_seqnos(Peer, HighSeqno, CommittedSeqno, Data) ->
    update_peer_status(
      Peer,
      fun (#peer_status{acked_seqno = AckedSeqno} = PeerStatus) ->
              true = (HighSeqno >= AckedSeqno),
              true = (HighSeqno >= CommittedSeqno),

              %% Note, that we update needs_sync without waiting for the
              %% response. If there's an error, we'll reinitialize peer's
              %% status and decide again if it needs explicit syncing.
              PeerStatus#peer_status{needs_sync = false,
                                     sent_seqno = HighSeqno,
                                     sent_commit_seqno = CommittedSeqno}
      end, Data).

set_peer_acked_seqnos(Peer, HighSeqno, CommittedSeqno, Data) ->
    update_peer_status(
      Peer,
      fun (#peer_status{sent_seqno = SentHighSeqno,
                        sent_commit_seqno = SentCommittedSeqno} = PeerStatus) ->
              true = (SentHighSeqno >= HighSeqno),
              true = (SentCommittedSeqno >= CommittedSeqno),

              PeerStatus#peer_status{acked_seqno = HighSeqno,
                                     acked_commit_seqno = CommittedSeqno}
      end, Data).

remove_peer_status(Peer, Data) ->
    remove_peer_statuses([Peer], Data).

remove_peer_statuses(Peers, #data{peer_statuses = Tab}) ->
    lists:foreach(
      fun (Peer) ->
              ets:delete(Tab, Peer)
      end, Peers).

send_requests(Peers, Request, Data, Fun) ->
    NewData = monitor_agents(Peers, Data),
    lists:foreach(
      fun (Peer) ->
              {ok, Ref} = get_peer_monitor(Peer, NewData),
              Opaque = {agent_response, Ref, Peer, Request},
              Fun(Peer, Opaque)
      end, Peers),

    NewData.

send_local_establish_term(Metadata,
                          #data{history_id = HistoryId, term = Term} = Data) ->
    Position = get_position(Metadata),

    send_requests(
      [?PEER()], {establish_term, HistoryId, Term, Position}, Data,
      fun (_Peer, Opaque) ->
              self() ! {Opaque, {ok, Metadata}}
      end).

send_establish_term(Peers, Metadata,
                    #data{history_id = HistoryId, term = Term} = Data) ->
    Position = get_position(Metadata),
    Request = {establish_term, HistoryId, Term, Position},
    send_requests(
      Peers, Request, Data,
      fun (Peer, Opaque) ->
              ?DEBUG("Sending establish_term request to peer ~p. "
                     "Term = ~p. History Id: ~p. "
                     "Log position: ~p.",
                     [Peer, Term, HistoryId, Position]),

              chronicle_agent:establish_term(Peer, Opaque,
                                             HistoryId, Term, Position)
      end).

send_append(PeersInfo0,
            #data{history_id = HistoryId,
                  term = Term,
                  committed_seqno = CommittedSeqno,
                  pending_high_seqno = HighSeqno} = Data) ->
    Request = {append, HistoryId, Term, CommittedSeqno, HighSeqno},

    PeersInfo = maps:from_list(PeersInfo0),
    Peers = maps:keys(PeersInfo),

    send_requests(
      Peers, Request, Data,
      fun (Peer, Opaque) ->
              PeerSeqno = maps:get(Peer, PeersInfo),
              Entries = get_entries(PeerSeqno, Data),
              set_peer_sent_seqnos(Peer, HighSeqno, CommittedSeqno, Data),
              ?DEBUG("Sending append request to peer ~p.~n"
                     "History Id: ~p~n"
                     "Term: ~p~n"
                     "Committed Seqno: ~p~n"
                     "Entries:~n~p",
                     [Peer, HistoryId, Term, CommittedSeqno, Entries]),

              chronicle_agent:append(Peer, Opaque,
                                     HistoryId, Term, CommittedSeqno, Entries)
      end).

%% TODO: think about how to backfill peers properly
get_entries(Seqno, #data{high_seqno = HighSeqno,
                         pending_entries = PendingEntries} = Data) ->
    BackfillEntries =
        case Seqno < HighSeqno of
            true ->
                get_local_log(Seqno + 1, HighSeqno, Data);
            false ->
                []
        end,

    %% TODO: consider storing pending entries more effitiently, so we don't
    %% have to traverse them here
    Entries =
        queue_dropwhile(
          fun (Entry) ->
                  Entry#log_entry.seqno =< Seqno
          end, PendingEntries),

    BackfillEntries ++ queue:to_list(Entries).

get_local_log(StartSeqno, EndSeqno,
              #data{history_id = HistoryId, term = Term}) ->
    %% TODO: handle errors better
    {ok, Log} = chronicle_agent:get_log(HistoryId, Term, StartSeqno, EndSeqno),
    Log.

send_ensure_term(Peers, Request,
                 #data{history_id = HistoryId, term = Term} = Data) ->
    send_requests(
      Peers, Request, Data,
      fun (Peer, Opaque) ->
              chronicle_agent:ensure_term(Peer, Opaque, HistoryId, Term)
      end).

send_request_peer_position(Peer, Data) ->
    send_request_position([Peer], Data).

send_request_position(Peers, Data) ->
    send_ensure_term(Peers, peer_position, Data).

queue_takefold(Fun, Acc, Queue) ->
    case queue:out(Queue) of
        {empty, _} ->
            {Acc, Queue};
        {{value, Value}, NewQueue} ->
            case Fun(Value, Acc) of
                {true, NewAcc} ->
                    queue_takefold(Fun, NewAcc, NewQueue);
                false ->
                    {Acc, Queue}
            end
    end.

-ifdef(TEST).
queue_takefold_test() ->
    Q = queue:from_list(lists:seq(1, 10)),
    MkFun = fun (CutOff) ->
                    fun (V, Acc) ->
                            case V =< CutOff of
                                true ->
                                    {true, Acc+V};
                                false ->
                                    false
                            end
                    end
            end,

    Test = fun (ExpectedSum, ExpectedTail, CutOff) ->
                   {Sum, NewQ} = queue_takefold(MkFun(CutOff), 0, Q),
                   ?assertEqual(ExpectedSum, Sum),
                   ?assertEqual(ExpectedTail, queue:to_list(NewQ))
           end,

    Test(0, lists:seq(1,10), 0),
    Test(15, lists:seq(6,10), 5),
    Test(55, [], 42).
-endif.

queue_dropwhile(Pred, Queue) ->
    {_, NewQueue} =
        queue_takefold(
          fun (Value, _) ->
                  case Pred(Value) of
                      true ->
                          {true, unused};
                      false ->
                          false
                  end
          end, unused, Queue),
    NewQueue.

-ifdef(TEST).
queue_dropwhile_test() ->
    Q = queue:from_list(lists:seq(1, 10)),
    Test = fun (Expected, CutOff) ->
                   NewQ = queue_dropwhile(fun (V) -> V =< CutOff end, Q),
                   ?assertEqual(Expected, queue:to_list(NewQ))
           end,
    Test(lists:seq(1,10), 0),
    Test(lists:seq(6,10), 5),
    Test([], 42).
-endif.

reply_request(From, Reply, Data) ->
    reply_requests([{From, Reply}], Data).

reply_requests(Replies, #data{parent = Parent}) ->
    chronicle_server:reply_requests(Parent, Replies).

monitor_agents(Peers,
               #data{monitors_peers = MPeers, monitors_refs = MRefs} = Data) ->
    {NewMPeers, NewMRefs} =
        lists:foldl(
          fun (Peer, {AccMPeers, AccMRefs} = Acc) ->
                  case maps:is_key(Peer, AccMPeers) of
                      true ->
                          %% already monitoring
                          Acc;
                      false ->
                          MRef = chronicle_agent:monitor(Peer),
                          {AccMPeers#{Peer => MRef}, AccMRefs#{MRef => Peer}}
                  end
          end, {MPeers, MRefs}, Peers),

    Data#data{monitors_peers = NewMPeers, monitors_refs = NewMRefs}.

demonitor_agents(Peers,
                 #data{monitors_peers = MPeers, monitors_refs = MRefs} =
                     Data) ->
    {NewMPeers, NewMRefs} =
        lists:foldl(
          fun (Peer, {AccMPeers, AccMRefs} = Acc) ->
                  case maps:take(Peer, AccMPeers) of
                      {MRef, NewAccMPeers} ->
                          erlang:demonitor(MRef, [flush]),
                          {NewAccMPeers, maps:remove(MRef, AccMRefs)};
                      error ->
                          Acc
                  end
          end, {MPeers, MRefs}, Peers),

    Data#data{monitors_peers = NewMPeers, monitors_refs = NewMRefs}.

take_monitor(MRef,
             #data{monitors_peers = MPeers, monitors_refs = MRefs} = Data) ->
    case maps:take(MRef, MRefs) of
        {Peer, NewMRefs} ->
            NewMPeers = maps:remove(Peer, MPeers),
            {ok, Peer, Data#data{monitors_peers = NewMPeers,
                                 monitors_refs = NewMRefs}};
        error ->
            not_found
    end.

get_peer_monitor(Peer, #data{monitors_peers = MPeers}) ->
    case maps:find(Peer, MPeers) of
        {ok, _} = Ok ->
            Ok;
        error ->
            not_found
    end.

get_monitored_peers(#data{monitors_peers = MPeers}) ->
    maps:keys(MPeers).

deduce_committed_seqno(#data{peers = Peers,
                             quorum = Quorum} = Data) ->
    PeerSeqnos =
        lists:filtermap(
          fun (Peer) ->
                  case get_peer_status(Peer, Data) of
                      {ok, #peer_status{acked_seqno = AckedSeqno}}
                        when AckedSeqno =/= ?NO_SEQNO ->
                          {true, {Peer, AckedSeqno}};
                      _ ->
                          false
                  end
          end, Peers),

    deduce_committed_seqno(PeerSeqnos, Quorum).

deduce_committed_seqno(PeerSeqnos0, Quorum) ->
    PeerSeqnos =
        %% Order peers in the decreasing order of their seqnos.
        lists:sort(fun ({_PeerA, SeqnoA}, {_PeerB, SeqnoB}) ->
                           SeqnoA >= SeqnoB
                   end, PeerSeqnos0),

    deduce_committed_seqno_loop(PeerSeqnos, Quorum, sets:new()).

deduce_committed_seqno_loop([], _Quroum, _Votes) ->
    no_quorum;
deduce_committed_seqno_loop([{Peer, Seqno} | Rest], Quorum, Votes) ->
    NewVotes = sets:add_element(Peer, Votes),
    case have_quorum(NewVotes, Quorum) of
        true ->
            {ok, Seqno};
        false ->
            deduce_committed_seqno_loop(Rest, Quorum, NewVotes)
    end.

-ifdef(TEST).
deduce_committed_seqno_test() ->
    Peers = [a, b, c, d, e],
    Quorum = {joint,
              {all, sets:from_list([a])},
              {majority, sets:from_list(Peers)}},

    ?assertEqual(no_quorum, deduce_committed_seqno([], Quorum)),
    ?assertEqual(no_quorum, deduce_committed_seqno([{a, 1}, {b, 3}], Quorum)),
    ?assertEqual({ok, 1},
                 deduce_committed_seqno([{a, 1}, {b, 1},
                                         {c, 3}, {d, 1}, {e, 2}], Quorum)),
    ?assertEqual({ok, 1},
                 deduce_committed_seqno([{a, 1}, {b, 1},
                                         {c, 3}, {d, 3}, {e, 2}], Quorum)),
    ?assertEqual({ok, 2},
                 deduce_committed_seqno([{a, 2}, {b, 1},
                                         {c, 3}, {d, 3}, {e, 2}], Quorum)),
    ?assertEqual({ok, 1},
                 deduce_committed_seqno([{a, 1}, {b, 3},
                                         {c, 3}, {d, 3}, {e, 2}], Quorum)),
    ?assertEqual({ok, 3},
                 deduce_committed_seqno([{a, 3}, {b, 3},
                                         {c, 3}, {d, 3}, {e, 2}], Quorum)),

    NewPeers = [a, b, c],
    JointQuorum = {joint,
                   {all, sets:from_list([a])},
                   {joint,
                    {majority, sets:from_list(Peers)},
                    {majority, sets:from_list(NewPeers)}}},

    ?assertEqual(no_quorum,
                 deduce_committed_seqno([{c, 1}, {d, 1}, {e, 1}], JointQuorum)),
    ?assertEqual({ok, 1},
                 deduce_committed_seqno([{a, 1}, {b, 1},
                                         {c, 2}, {d, 2}, {e, 2}], JointQuorum)),
    ?assertEqual({ok, 1},
                 deduce_committed_seqno([{a, 2}, {b, 2},
                                         {c, 1}, {d, 1}, {e, 1}], JointQuorum)),
    ?assertEqual({ok, 1},
                 deduce_committed_seqno([{a, 1}, {b, 2}, {c, 2},
                                         {d, 3}, {e, 1}], JointQuorum)),
    ?assertEqual({ok, 2},
                 deduce_committed_seqno([{a, 2}, {b, 2}, {c, 1},
                                         {d, 3}, {e, 1}], JointQuorum)).
-endif.
