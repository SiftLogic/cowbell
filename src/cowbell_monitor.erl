%% ==========================================================================================================
%% Cowbell -A node connection manager that handles reconnections in dynamic environments.
%%
%% The MIT License (MIT)
%%
%% Copyright (c) 2016 Roberto Ostinelli <roberto@ostinelli.net>.
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% ==========================================================================================================
-module(cowbell_monitor).
-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([add/1]).
-export([remove/1]).
-export([status/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% macros
-define(DEFAULT_CHECK_INTERVAL_SEC, 10).
-define(DEFAULT_ABANDON_NODE_AFTER_SEC, 86400).

%% records
-record(state, {
          check_interval_sec = 0 :: non_neg_integer(),
          abandon_node_after_sec :: non_neg_integer(),
          timer_ref = undefined :: undefined | reference()
         }).

%% ===================================================================
%% API
%% ===================================================================
-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
    Options = [],
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], Options).

-spec add(Node :: node()) -> ok | {error, connect_failed}.
add(Node) ->
    gen_server:call(?MODULE, {add, Node}).

-spec remove(Node :: node()) -> ok.
remove(Node) ->
    gen_server:cast(?MODULE, {remove, Node}).

-spec status(Node :: node()) -> {connected, non_neg_integer()} |
                                {disconnected, non_neg_integer(), non_neg_integer()} |
                                {abandoned, non_neg_integer()} |
                                {error, not_monitored}.
status(Node) ->
    node_status(Node).

%% ===================================================================
%% Callbacks
%% ===================================================================

%% ----------------------------------------------------------------------------------------------------------
%% Init
%% ----------------------------------------------------------------------------------------------------------
-spec init([]) ->
                  {ok, #state{}} |
                  {ok, #state{}, Timeout :: non_neg_integer()} |
                  ignore |
                  {stop, Reason :: any()}.
init([]) ->
    %% get preferences
    CheckIntervalSec = application:get_env(cowbell, check_interval_sec, ?DEFAULT_CHECK_INTERVAL_SEC),
    AbandonNodeAfterSec = application:get_env(cowbell, abandon_node_after_sec, ?DEFAULT_ABANDON_NODE_AFTER_SEC),
    MonitoredNodes = application:get_env(cowbell, nodes, []),
    ok = net_kernel:monitor_nodes(true),
    ok = init_monitors(MonitoredNodes),
    %% build state
    {ok, timeout(#state{
                    check_interval_sec = CheckIntervalSec,
                    abandon_node_after_sec = AbandonNodeAfterSec
                   })}.

%% ----------------------------------------------------------------------------------------------------------
%% Call messages
%% ----------------------------------------------------------------------------------------------------------
-spec handle_call(Request :: any(), From :: any(), #state{}) ->
                         {reply, Reply :: any(), #state{}} |
                         {reply, Reply :: any(), #state{}, Timeout :: non_neg_integer()} |
                         {noreply, #state{}} |
                         {noreply, #state{}, Timeout :: non_neg_integer()} |
                         {stop, Reason :: any(), Reply :: any(), #state{}} |
                         {stop, Reason :: any(), #state{}}.

handle_call({add, Node}, _From, State) ->
    case node_status(Node) of
        {ok, connected} ->
            %% Already monitored
            {reply, ok, State};
        {ok, abandoned} ->
            case net_kernel:connect_node(Node) of
                true ->
                    ok = set_connected(Node),
                    {reply, ok, State};
                Error ->
                    error_logger:warning_msg("Cannot connect to abandoned node '~p',"
                                             " will try again: ~p",
                                             [Node, Error]),
                    %% Could not connect, add to disconnected
                    ok = set_disconnected(Node),
                    {reply, {error, connect_failed}, State}
            end;
        {ok, disconnected} ->
            case net_kernel:connect_node(Node) of
                true ->
                    ok = set_connected(Node),
                    {reply, ok, State};
                Error ->
                    error_logger:warning_msg("Cannot connect to disconnected node '~p',"
                                             " will try again: ~p",
                                             [Node, Error]),
                    %% Could not connect, add to disconnected
                    ok = set_disconnected(Node),
                    {reply, {error, connect_failed}, State}
            end;
        {error, not_monitored} ->
            {reply, case do_connect(Node) of
                        {error, _} = E ->
                            set_disconnected(Node),
                            E;
                        ok ->
                            ok
                    end, State}
    end;
handle_call(Request, From, State) ->
    error_logger:warning_msg("Received from ~p an unknown call message: ~p", [Request, From]),
    {reply, undefined, State}.

%% ----------------------------------------------------------------------------------------------------------
%% Cast messages
%% ----------------------------------------------------------------------------------------------------------
-spec handle_cast(Msg :: any(), #state{}) ->
                         {noreply, #state{}} |
                         {noreply, #state{}, Timeout :: non_neg_integer()} |
                         {stop, Reason :: any(), #state{}}.

handle_cast({remove, Node}, State) ->
    ok = remove_node(Node),
    {noreply, State};

handle_cast(Msg, State) ->
    error_logger:warning_msg("Received an unknown cast message: ~p", [Msg]),
    {noreply, State}.

%% ----------------------------------------------------------------------------------------------------------
%% All non Call / Cast messages
%% ----------------------------------------------------------------------------------------------------------
-spec handle_info(Info :: any(), #state{}) ->
                         {noreply, #state{}} |
                         {noreply, #state{}, Timeout :: non_neg_integer()} |
                         {stop, Reason :: any(), #state{}}.

handle_info({nodedown, Node}, #state{check_interval_sec = CheckIntervalSec,
                                     abandon_node_after_sec = AbandonNodeAfterSec} = State) ->
    ok = set_disconnected(Node),
    error_logger:warning_msg(
      "Node '~p' got disconnected, will try reconnecting every ~p seconds for a max of ~p seconds",
      [Node, CheckIntervalSec, AbandonNodeAfterSec]
     ),
    {noreply, timeout(State)};

handle_info({nodeup, Node}, #state{
                              } = State) ->
    ok = set_connected(Node),
    error_logger:info_msg("Node '~p' got connected", [Node]),
    %% return
    {noreply, timeout(State)};

handle_info(connect_nodes, State) ->
    io:format("Attempting to reconnect nodes~n"),
    %% reconnect disconnected nodes
    ok = reconnect(),
    {noreply, timeout(State)};

handle_info(Info, State) ->
    error_logger:warning_msg("Received an unknown info message: ~p", [Info]),
    {noreply, State}.

%% ----------------------------------------------------------------------------------------------------------
%% Terminate
%% ----------------------------------------------------------------------------------------------------------
-spec terminate(Reason :: any(), #state{}) -> terminated.
terminate(Reason, _State) ->
    error_logger:info_msg("Terminating cowbell monitor with reason: ~p", [Reason]),
    %% return
    terminated.

%% ----------------------------------------------------------------------------------------------------------
%% Convert process state when code is changed.
%% ----------------------------------------------------------------------------------------------------------
-spec code_change(OldVsn :: any(), #state{}, Extra :: any()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Internal
%% ===================================================================

-spec epoch_time() -> non_neg_integer().
epoch_time() ->
    {M, S, _} = os:timestamp(),
    M * 1000000 + S.

-spec timeout(#state{}) -> #state{}.
timeout(#state{
           check_interval_sec = CheckIntervalSec,
           timer_ref = TimerPrevRef
          } = State) ->
    case TimerPrevRef of
        undefined -> ignore;
        _ -> erlang:cancel_timer(TimerPrevRef)
    end,
    TimerRef = erlang:send_after(CheckIntervalSec * 1000, self(), connect_nodes),
    State#state{timer_ref = TimerRef}.

node_status(Node) ->
    case ets:lookup(cowbell, Node) of
        [{Node, {R, _, _}}] ->
            {ok, R};
        [{Node, {R, _}}] ->
            {ok, R};
        [] ->
            {error, not_monitored}
    end.

do_connect(Node) ->
    case net_kernel:connect_node(Node) of
        true ->
            set_connected(Node);
        _Error ->
            {error, failed_to_connect}
    end.

set_connected(Node) ->
    Tstamp = epoch_time(),
    true = ets:insert(cowbell, {Node, {connected, Tstamp}}),
    ok.

set_disconnected(Node) ->
    Tstamp = epoch_time(),
    true = case ets:lookup(cowbell, Node) of
               [{Node, {disconnected, FirstTstamp, _LastTstamp}}]
                 when FirstTstamp + ?DEFAULT_ABANDON_NODE_AFTER_SEC =< Tstamp ->
                   ets:insert(cowbell, {Node, {abandoned, Tstamp}});
               [{Node, {disconnected, FirstTstamp, _LastTstamp}}] ->
                   ets:insert(cowbell, {Node, {disconnected, FirstTstamp, Tstamp}});
               [{Node, {connected, _LastTstamp}}] ->
                   ets:insert(cowbell, {Node, {disconnected, Tstamp, Tstamp}});
               [{Node, {abandoned, _LastTstamp}}] ->
                   ets:insert(cowbell, {Node, {disconnected, Tstamp, Tstamp}});
               [] ->
                   ets:insert(cowbell, {Node, {disconnected, Tstamp, Tstamp}})
           end,
    ok.

remove_node(Node) ->
    _ = erlang:disconnect_node(Node),
    true = ets:delete(cowbell, Node),
    ok.

-spec init_monitors(MonitoredNodes :: [node()]) -> ok.
init_monitors(MonitorNodes0) ->
    MonitorNodes =
        ets:foldl(fun({Node, _}, MonNodes) ->
                          case do_connect(Node) of
                              ok ->
                                  ok;
                              {error, failed_to_connect} ->
                                  ok = set_disconnected(Node)
                          end,
                          lists:delete(Node, MonNodes)
                  end, MonitorNodes0, cowbell),
    do_init_monitor(MonitorNodes).

do_init_monitor([]) ->
    ok;
do_init_monitor([Node | Rest]) ->
    case do_connect(Node) of
        ok ->
            ok;
        {error, failed_to_connect} ->
            ok = set_disconnected(Node)
    end,
    do_init_monitor(Rest).

reconnect() ->
    ets:foldl(
      fun({Node, {disconnected, _Start, Last}}, _)->
              Tstamp = epoch_time(),
              case Last + ?DEFAULT_CHECK_INTERVAL_SEC < Tstamp of
                  true ->
                      case do_connect(Node) of
                          ok ->
                              ok;
                          {error, failed_to_connect} ->
                              ok = set_disconnected(Node)
                      end;
                  false ->
                      ok
              end;
         (_Node, _R) ->
              ok
      end, ok, cowbell).