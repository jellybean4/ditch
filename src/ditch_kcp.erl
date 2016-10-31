%%%-------------------------------------------------------------------
%%% @author jacky
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 07. 七月 2016 15:36
%%%-------------------------------------------------------------------
-module(ditch_kcp).
-author("jacky").

-behaviour(gen_server).
-include("ditch.hrl").
-include_lib("kernel/src/inet_int.hrl").

%% API
-export([start_link/4,
  send_data/2,
  dump_kcp/1,
  name/0]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {sock :: inet:socket(),
  callback :: any(),
  cb_pid :: pid(),
  next_conv :: non_neg_integer()}).

%%%===================================================================
%%% API
%%%===================================================================
name() ->
  ditch_kcp.

send_data(KCP = #kcp_pcb{mss = Mss}, Data) ->
  DataList = util:binary_split(Data, Mss),
  send_data2(KCP, DataList, length(DataList) - 1).

send_data2(KCP, [], 0) -> KCP;
send_data2(KCP = #kcp_pcb{snd_queue = SndQue}, [Data | Left], Frg) ->
  Seg = #kcp_seg{len = byte_size(Data), frg = Frg, data = Data},
  SndQue2 = ditch_queue:in(Seg, SndQue),
  KCP2 = KCP#kcp_pcb{snd_queue = SndQue2},
  send_data2(KCP2, Left, Frg - 1).


%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link(DitchOpts :: any(), Callback :: module(), Callback :: any(), Args::any()) ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(DitchOpts, Callback, CallbackOpts, Args) ->
  gen_server_boot:start_link(?MODULE, [DitchOpts, Callback, CallbackOpts, Args], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([DitchOpts, Callback, CallbackOpts, Args]) ->
  UDPOpts = proplists:get_value(udp_opts, DitchOpts, ?UDP_SOCK_OPTS),
  erlang:process_flag(trap_exit, true),
  case gen_udp:open(0, UDPOpts) of
    {error, Reason} ->
      ?ERRORLOG("open kcp listener failed, reason ~p", [Reason]),
      {stop, Reason};
    {ok, Socket} ->
      case Callback:start_link(CallbackOpts, Args) of
        {ok, PID} ->
          timer:send_after(?KCP_INTERVAL, self(), kcp_update),
          {ok, #state{sock = Socket, callback = Callback, cb_pid = PID, next_conv = rand_num:next(?CONV_START_LIMIT)}};
        {stop, Reason} ->
          {stop, Reason}
      end
  end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
  {reply, Reply :: term(), NewState :: #state{}} |
  {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
%% stop when proc process terminate
handle_info({'EXIT', From, Reason}, State = #state{cb_pid = From}) ->
  {stop, {cb_terminate, Reason}, State};

%% change into active when no more active for stream change
handle_info({udp_passive, Socket}, State = #state{sock = Socket}) ->
  inet:setopts(Socket, {active, 10}),
  {noreply, State};

%% New Data arrived
handle_info({udp, Socket, IP, InPortNo, Packet}, State = #state{sock = Socket}) ->
  ?DEBUGLOG("rcv data from ~p", [{IP, InPortNo}]),
  case try_handle_pkg(IP, InPortNo, Packet, State) of
    {ok, State2} ->
      ?DEBUGLOG("handle kcp pkg success"),
      {noreply, State2};
    {stop, Reason, State2} ->
      ?ERRORLOG("stoping kcp handler, reason ~w", [Reason]),
      {stop, Reason, State2};
    {error, Reason, State2} ->
      ?ERRORLOG("handle kcp pkg failed, reason ~w", [Reason]),
      dump_kcp(get({IP, InPortNo})),
      {noreply, State2}
  end;

%% Flush all datas
handle_info(kcp_update, State) ->
  Keys = erlang:get(),
  Now = util:timenow_mill(),
  [begin
     KCP2 = kcp_update(Now, State#state.sock, KCP),
     put(Key, KCP2)
   end || {Key, KCP} <- Keys, is_record(KCP, kcp_pcb)],
  timer:send_after(?KCP_INTERVAL, self(), kcp_update),
  {noreply, State};

handle_info(Info, State) ->
  ?ERRORLOG("receiving unknown info[~w]", [Info]),
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State) ->
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
  {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================


%%--------------------------------------------------------------------
%% @private
%% @doc
%% KCP related logic
%%--------------------------------------------------------------------
try_handle_pkg(IP, Port, Data, State) ->
  try
    handle_recv_pkg(IP, Port, Data, State)
  catch
    Error: Reason ->
      Stack = erlang:get_stacktrace(),
      ?ERRORLOG("Error occurs while processing udp package ~p", [Stack]),
      {error, {Error, Reason}, State}
  end.

handle_recv_pkg(IP, Port, Data, State) ->
  Args = {undefined, undefined},
  OldKCP = get({IP, Port}),
  case handle_recv_pkg2(OldKCP, IP, Port, State, Args, Data) of
    {ok, State2 = #state{cb_pid = RecvPID}} ->
      KCP = get({IP, Port}),
      KCP2 = check_data_rcv(IP, Port, OldKCP, KCP, RecvPID),
      put({IP, Port}, KCP2),
      {ok, State2};
    {error, Reason, State2} ->
      ?ERRORLOG("proc kcp packag failed, reason [~w]", [Reason]),
      {error, Reason, State2};
    {stop, Reason, State2} -> {stop, Reason, State2}
  end.

%% No more data need to be processed.
handle_recv_pkg2(KCP, IP, Port, State, {MaxAck, Una}, <<>>) ->
  case KCP of
    undefined ->
      {error, empty_data, State};
    #kcp_pcb{} ->
      KCP2 = kcp_rcv_finish(KCP, MaxAck, Una),
      put({IP, Port}, KCP2),
      {ok, State}
  end;

%% Sync message recved
handle_recv_pkg2(KCP, IP, Port, State, {MaxAck, _},
    ?KCP_SEG(Conv, ?KCP_CMD_PUSH, Frg, Wnd, Ts, Sn, Una, Len, Data, Left)) ->
  case KCP of
    undefined when Conv =/= 0 ->
      {error, "first kcp package conv not zero", State};
    #kcp_pcb{conv = KConv} when Conv =/= KConv ->
      ?ERRORLOG("conv id not match ~p/~p", [KConv, Conv]),
      {error, "conv id not match"};
    _ ->
      {KCP2, State2} = case KCP of
        undefined ->
          #state{next_conv = NextConv} = State,
          PCB = #kcp_pcb{conv = NextConv, key = {IP, Port}, state = ?KCP_STATE_ACTIVE,
            rmt_wnd = Wnd, probe = ?KCP_SYNC_ACK_SEND},
          put({IP, Port}, PCB),
          {PCB, State#state{next_conv = NextConv + 1}};
        PCB -> {PCB, State}
      end,
      KCP3 = kcp_parse_una(KCP2#kcp_pcb{rmt_wnd = Wnd}, Una),
      KCP4 = kcp_shrink_buf(KCP3),
      case Sn < (KCP4#kcp_pcb.rcv_nxt + KCP4#kcp_pcb.rcv_wnd) of
        false -> handle_recv_pkg2(KCP4, IP, Port, State2, {MaxAck, Una}, Left);
        true  ->
          KCP5 = kcp_ack_push(KCP4, Sn, Ts),
          KCP6 = case Sn >= KCP5#kcp_pcb.rcv_nxt of
            false -> KCP5;
            true  ->
              Seg = #kcp_seg{conv = Conv, cmd = ?KCP_CMD_PUSH, wnd = Wnd, frg = Frg, ts = Ts, sn = Sn, una = Una, len = Len, data = Data},
              kcp_parse_data(KCP5, Seg)
          end,
          handle_recv_pkg2(KCP6, IP, Port, State2, {MaxAck, Una}, Left)
      end
  end;

handle_recv_pkg2(KCP, IP, Port, State, {MaxAck, _},
    ?KCP_SEG(Conv, ?KCP_CMD_ACK, 0, Wnd, Ts, Sn, Una, 0, _Data, Left)) ->
  case KCP of
    undefined ->
      ?ERRORLOG("recv unconnected ack seg from ~p", [{IP, Port}]),
      {error, "cound not find kcp"};
    #kcp_pcb{conv = KConv} when Conv =/= KConv ->
      ?ERRORLOG("conv id not match ~p/~p", [KConv, Conv]),
      {error, "conv id not match"};
    #kcp_pcb{} ->
      KCP2 = kcp_parse_una(KCP#kcp_pcb{rmt_wnd = Wnd}, Una),
      KCP3 = kcp_shrink_buf(KCP2),
      KCP4 = kcp_update_ack(KCP3, KCP3#kcp_pcb.current - Ts),
      KCP5 = kcp_parse_ack(KCP4, Sn),
      KCP6 = kcp_shrink_buf(KCP5),
      MaxAck2 = case MaxAck of
        undefined -> Sn;
        MaxAck when Sn > MaxAck -> Sn;
        MaxAck -> MaxAck
      end,
      handle_recv_pkg2(KCP6, IP, Port, State, {MaxAck2, Una}, Left)
  end;

handle_recv_pkg2(KCP, IP, Port, State, {MaxAck, _},
    ?KCP_SEG(Conv, ?KCP_CMD_WASK, 0, Wnd, _Ts, _Sn, Una, 0, _Data, Left)) ->
  case KCP of
    undefined ->
      {error, "cound not find kcp"};
    #kcp_pcb{conv = KConv} when KConv =/= Conv ->
      {error, "conv id not match"};
    #kcp_pcb{} ->
      KCP2 = kcp_parse_una(KCP#kcp_pcb{rmt_wnd = Wnd}, Una),
      KCP3 = kcp_shrink_buf(KCP2),
      KCP4 = KCP3#kcp_pcb{probe = KCP3#kcp_pcb.probe bor ?KCP_ASK_TELL},
      handle_recv_pkg2(KCP4, IP, Port, State, {MaxAck, Una}, Left)
  end;

handle_recv_pkg2(KCP, IP, Port, State, {MaxAck, _},
    ?KCP_SEG(Conv, ?KCP_CMD_WINS, 0, Wnd, _Ts, _Sn, Una, 0, _Data, Left)) ->
  case KCP of
    undefined ->
      {error, "cound not find kcp"};
    #kcp_pcb{conv = KConv} when KConv =/= Conv ->
      {error, "conv id not match"};
    #kcp_pcb{} ->
      KCP2 = kcp_parse_una(KCP#kcp_pcb{rmt_wnd = Wnd}, Una),
      KCP3 = kcp_shrink_buf(KCP2),
      handle_recv_pkg2(KCP3, IP, Port, State, {MaxAck, Una}, Left)
  end;

handle_recv_pkg2(KCP, IP, Port, _State, _MaxAck, _Data) ->
  ?ERRORLOG("recv unknown data ~p segment from ~p for pcb", [_Data, {IP, Port}, KCP]),
  {error, "unknown pkg format"}.


%% Increase FaskAck count for each segment
kcp_parse_fastack(KCP = #kcp_pcb{snd_una = SndUna, snd_nxt = SndNxt}, Sn)
    when SndUna > Sn; Sn >= SndNxt -> KCP;
kcp_parse_fastack(KCP, Sn) ->
  FirstIdx = ditch_buffer:first(KCP#kcp_pcb.snd_buf),
  SndBuf2 = kcp_parse_fastack2(KCP#kcp_pcb.snd_buf, FirstIdx, Sn),
  KCP#kcp_pcb{snd_buf = SndBuf2}.

kcp_parse_fastack2(SndBuf, ?LAST_INDEX, _) -> SndBuf;
kcp_parse_fastack2(SndBuf, Idx, Sn) ->
  case ditch_buffer:get_data(Idx, SndBuf) of
    undefined ->
      Next = ditch_buffer:next(SndBuf, Idx),
      kcp_parse_fastack2(SndBuf, Next, Sn);
    Seg when Seg#kcp_seg.sn > Sn ->
      kcp_parse_fastack2(SndBuf, ?LAST_INDEX, Sn);
    Seg = #kcp_seg{fastack = FastAck} ->
      Seg2 = Seg#kcp_seg{fastack = FastAck + 1},
      SndBuf2 = ditch_buffer:set_data(Idx, Seg2, SndBuf),
      Next = ditch_buffer:next(SndBuf2, Idx),
      kcp_parse_fastack2(SndBuf2, Next, Sn)
  end.

%% update kcp rx_rttval, rx_srtt and rx_rto
kcp_update_ack(KCP, RTT) when RTT < 0 -> KCP;
kcp_update_ack(KCP, RTT) ->
  KCP2 = case KCP#kcp_pcb.rx_srtt =:= 0 of
    true ->
      KCP#kcp_pcb{rx_srtt = RTT, rx_rttval = RTT div 2};
    false ->
      Delta = RTT - KCP#kcp_pcb.rx_srtt,
      Delta2 = case Delta < 0 of
        true  -> -Delta;
        false -> Delta
      end,
      RxRttVal = (3 * KCP#kcp_pcb.rx_rttval + Delta2) div 4,
      RxSRttVal = (7 * KCP#kcp_pcb.rx_srtt + RTT) div 8,
      RxSRttVal2 = case RxSRttVal < 1 of
        true -> 1;
        false -> RxSRttVal
      end,
      KCP#kcp_pcb{rx_srtt = RxSRttVal2, rx_rttval = RxRttVal}
  end,
  Rto = KCP2#kcp_pcb.rx_srtt + lists:max([1, 4 * KCP2#kcp_pcb.rx_rttval]),
  Rto2 = ?IBOUND(KCP2#kcp_pcb.rx_minrto, Rto, ?KCP_RTO_MAX),
  KCP2#kcp_pcb{rx_rto = Rto2}.

%% recalculate the snd_una
kcp_shrink_buf(KCP) ->
  #kcp_pcb{snd_buf = SndBuf, snd_nxt = SndNxt} = KCP,
  case ditch_buffer:first(SndBuf) of
    ?LAST_INDEX -> KCP#kcp_pcb{snd_una = SndNxt};
    Idx ->
      Seg = ditch_buffer:get_data(Idx, SndBuf),
      KCP#kcp_pcb{snd_una = Seg#kcp_seg.sn}
  end.

%% Erase acked seg from snd_buf
kcp_parse_ack(KCP = #kcp_pcb{snd_una = SndUna, snd_nxt = SndNxt}, Sn)
    when SndUna > Sn; SndNxt =< Sn ->
  KCP;
kcp_parse_ack(KCP, Sn) ->
  First = ditch_buffer:first(KCP#kcp_pcb.snd_buf),
  SndBuf2 = kcp_parse_ack2(KCP#kcp_pcb.snd_buf, First, ?LAST_INDEX, Sn),
  KCP#kcp_pcb{snd_buf = SndBuf2}.

kcp_parse_ack2(SndBuf, ?LAST_INDEX, _, _) -> SndBuf;
kcp_parse_ack2(SndBuf, Idx, Prev, Sn) ->
  {Next2, SndBuf2} = case ditch_buffer:get_data(Idx, SndBuf) of
    undefined ->
      Next = ditch_buffer:next(Idx, SndBuf),
      {Next, SndBuf};
    Seg when Seg#kcp_seg.sn =:= Sn ->
      Buf2 = ditch_buffer:delete(Idx, Prev, SndBuf),
      {?LAST_INDEX, Buf2};
    Seg when Seg#kcp_seg.sn > Sn ->
      {?LAST_INDEX, SndBuf};
    Seg when Seg#kcp_seg.sn < Sn ->
      Next = ditch_buffer:next(Idx, SndBuf),
      {Next, SndBuf}
  end,
  kcp_parse_ack2(SndBuf2, Next2, Idx, Sn).

%% Erase all recved seg from snd_buf
kcp_parse_una(KCP, Una) ->
  First = ditch_buffer:first(KCP#kcp_pcb.snd_buf),
  SndBuf2 = kcp_parse_una2(KCP#kcp_pcb.snd_buf, First, ?LAST_INDEX, Una),
  KCP#kcp_pcb{snd_buf = SndBuf2}.

kcp_parse_una2(SndBuf, ?LAST_INDEX, _, _) -> SndBuf;
kcp_parse_una2(SndBuf, Idx, Prev, Una) ->
  {Next2, SndBuf2} = case ditch_buffer:get_data(Idx, SndBuf) of
    undefined ->
      Next = ditch_buffer:next(Idx, SndBuf),
      {Next, SndBuf};
    Seg when Seg#kcp_seg.sn >= Una ->
      {?LAST_INDEX, SndBuf};
    _ ->
      Next = ditch_buffer:next(Idx, SndBuf),
      Buf2 = ditch_buffer:delete(Idx, Prev, SndBuf),
      {Next, Buf2}
  end,
  kcp_parse_una2(SndBuf2, Next2, Idx, Una).

kcp_rcv_finish(KCP, MaxAck, Una) ->
  KCP2 = case MaxAck of
    undefined -> KCP;
    _ -> kcp_parse_fastack(KCP, MaxAck)
  end,
  kcp_rcv_finish2(KCP2, Una).

kcp_rcv_finish2(KCP = #kcp_pcb{snd_una = SndUna, cwnd = Cwnd, rmt_wnd = Rwnd}, Una)
  when SndUna =< Una; Cwnd >= Rwnd -> KCP;
kcp_rcv_finish2(KCP, _Una) ->
  #kcp_pcb{mss = Mss, cwnd = Cwnd, incr = Incr, ssthresh = Ssth, rmt_wnd = Rwnd} = KCP,
  {Cwnd2, Incr2} = case Cwnd < Ssth of
    true ->
      {Cwnd + 1, Incr + Mss};
    false ->
      In2 = ?MAX(Incr, Mss),
      In3 = In2 + (Mss * Mss) div In2 + (Mss div 16),
      C2 = case (Cwnd + 1) * Mss =< In3 of
        true -> Cwnd + 1;
        false -> Cwnd
      end,
      {C2, In3}
  end,
  case Cwnd2 > Rwnd of
    false ->
      KCP#kcp_pcb{cwnd = Cwnd2, incr = Incr2};
    true  -> 
      KCP#kcp_pcb{cwnd = Rwnd, incr = Rwnd * Mss}
  end.

kcp_ack_push(KCP = #kcp_pcb{acklist = AckList}, Sn, Ts) ->
  KCP#kcp_pcb{acklist = [{Sn, Ts} | AckList]}.

kcp_parse_data(KCP = #kcp_pcb{rcv_nxt = RcvNxt, rcv_wnd = Rwnd}, #kcp_seg{sn = Sn})
    when Sn >= RcvNxt + Rwnd; Sn < RcvNxt -> KCP;
kcp_parse_data(KCP, Seg) ->
  #kcp_pcb{rcv_buf = RcvBuf, rcv_queue = RcvQue, rcv_nxt = RcvNxt} = KCP,
  First = ditch_buffer:first(RcvBuf),
  RcvBuf2 = kcp_parse_data2(RcvBuf, First, ?LAST_INDEX, Seg),
  {RcvNxt2, RcvBuf3, RcvQue2} = check_and_move(RcvNxt, RcvBuf2, RcvQue),
  KCP#kcp_pcb{rcv_buf = RcvBuf3, rcv_queue = RcvQue2, rcv_nxt = RcvNxt2}.

kcp_parse_data2(RcvBuf, ?LAST_INDEX, Prev, Seg) ->
  ditch_buffer:append(Prev, Seg, RcvBuf);
kcp_parse_data2(RcvBuf, Idx, Prev, Seg) ->
  Next = ditch_buffer:next(Idx, RcvBuf),
  case ditch_buffer:get_data(Idx, RcvBuf) of
    undefined ->
      RcvBuf;
    #kcp_seg{sn = Sn} when Sn =:= Seg#kcp_seg.sn -> RcvBuf;
    #kcp_seg{sn = Sn} when Sn < Seg#kcp_seg.sn ->
      kcp_parse_data2(RcvBuf, Next, Idx, Seg);
    #kcp_seg{sn = Sn} when Sn > Seg#kcp_seg.sn ->
      ditch_buffer:append(Prev, Seg, RcvBuf)
  end.

check_and_move(RcvNxt, RcvBuf, RcvQueue) ->
  First = ditch_buffer:first(RcvBuf),
  check_and_move2(RcvNxt, ?LAST_INDEX, First, RcvBuf, RcvQueue).

check_and_move2(RcvNxt, _, ?LAST_INDEX, RcvBuf, RcvQueue) ->
  {RcvNxt, RcvBuf, RcvQueue};
check_and_move2(RcvNxt, Prev, Idx, RcvBuf, RcvQueue) ->
  case ditch_buffer:get_data(Idx, RcvBuf) of
    undefined -> {RcvNxt, RcvBuf, RcvQueue};
    Seg = #kcp_seg{sn = Sn} when Sn =:= RcvNxt ->
      Next = ditch_buffer:next(Idx, RcvBuf),
      RcvBuf2 = ditch_buffer:delete(Idx, Prev, RcvBuf),
      RcvQueue2 = ditch_queue:in(Seg, RcvQueue),
      Prev2 = case ditch_buffer:first(RcvBuf2) =:= Next of
        true  -> ?LAST_INDEX;
        false -> Idx
      end,
      check_and_move2(RcvNxt + 1, Prev2, Next, RcvBuf2, RcvQueue2);
    _ -> {RcvNxt, RcvBuf, RcvQueue}
  end.

check_data_rcv(IP, Port, OldKCP, KCP, RecvPID) ->
  #kcp_pcb{rcv_queue = OldQue} = OldKCP,
  #kcp_pcb{rcv_queue = RcvQue, datalist = DataList, probe = Probe} = KCP,
  case ditch_queue:len(OldQue) =:= ditch_queue:len(RcvQue) of
    true  -> KCP;
    false ->
      {RcvQue2, DataList2} = check_data_rcv2(RcvQue, [], DataList),
      RecvPID ! {kcp_rcv_data, {IP, Port}},
      KCP#kcp_pcb{rcv_queue = RcvQue2, datalist = DataList2, probe = Probe bor ?KCP_ASK_TELL}
  end.

check_data_rcv2(RcvQue, PartList, DataList) ->
  case ditch_queue:is_empty(RcvQue) of
    true  -> {RcvQue, DataList};
    false ->
      case ditch_queue:get(RcvQue) of
        #kcp_seg{frg = Frg, data = Data} when Frg =:= 0 ->
          Data2 = util:binary_join(lists:reverse([Data | PartList])),
          RcvQue2 = ditch_queue:drop(RcvQue),
          check_data_rcv2(RcvQue2, [], [Data2 | DataList]);
        #kcp_seg{frg = Frg, data = Data} ->
          case ditch_queue:len(RcvQue) of
            QueSize when QueSize >= (Frg + 1) ->
              RcvQue2 = ditch_queue:drop(RcvQue),
              check_data_rcv2(RcvQue2, [Data | PartList], DataList);
            _ ->
              {RcvQue, DataList}
          end
      end
  end.

%% Flush all sndbuf data out
kcp_update(Now, Socket, KCP) ->
  #kcp_pcb{updated = Updated, ts_flush = TsFlush, interval = Interval} = KCP,
  {Updated2, TsFlush2} = case Updated =:= false of
    true -> {true, Now};
    false -> {Updated, TsFlush}
  end,
  Slap = Now - TsFlush2,
  {Slap2, TsFlush3} = case (Slap >= 10000) or (Slap < -10000) of
    true -> {0, Now};
    false -> {Slap, TsFlush2}
  end,
  case Slap2 >= 0 of
    false ->
      KCP#kcp_pcb{current = Now, ts_flush = TsFlush3, updated = Updated2};
    true  ->
      TsFlush4 = TsFlush3 + Interval,
      TsFlush5 = case Now > TsFlush4 of
        true -> Now + Interval;
        false -> TsFlush4
      end,
      kcp_flush(Socket, KCP#kcp_pcb{current = Now, ts_flush = TsFlush5, updated = Updated2})
  end.


kcp_flush(_Socket, KCP = #kcp_pcb{updated = false}) -> KCP;
kcp_flush(Socket, KCP) ->
  #kcp_pcb{conv = Conv, rcv_nxt = RcvNxt, rcv_queue = RcvQue, rcv_wnd = RWnd,
    current = Current, rx_rto = Rto} = KCP,
  Wnd = RWnd - ditch_queue:len(RcvQue),
  Seg = #kcp_seg{conv = Conv, cmd = ?KCP_CMD_ACK, frg = 0, wnd = Wnd, una = RcvNxt,
    ts = Current, rto = Rto, resendts = Current, fastack = 0, xmit = 0},
  {KCP2, Buf2} = kcp_flush_ack(Socket, KCP, Seg),
  {KCP3, Buf3} = kcp_probe_wnd(Socket, KCP2, Seg, Buf2),
  {KCP4, Buf4} = kcp_flush_wnd(Socket, KCP3, Seg, Buf3),
%%  {KCP5, Buf4} = kcp_flush_sync(Socket, KCP4, Seg, Buf3),
%%  {KCP6, Buf5} = kcp_flush_syncack(Socket, KCP5, Seg, Buf4),
  {KCP5, {Buf5, _Size5}} = kcp_flush_data(Socket, KCP4#kcp_pcb{probe = 0}, Seg, Buf4),
  kcp_output2(Socket, KCP5#kcp_pcb.key, util:binary_join(Buf5)),
  KCP5.

kcp_flush_ack(Socket, KCP = #kcp_pcb{key = Key, acklist = AckList, mtu = Mtu}, Seg) ->
  Buf = kcp_flush_ack2(Socket, Key, Seg, AckList, [], 0, Mtu),
  {KCP#kcp_pcb{acklist = []}, Buf}.
kcp_flush_ack2(_Socket, _Key, _Seg, [], Buf, Size, _Limit) -> {Buf, Size};
kcp_flush_ack2(Socket, Key, Seg, [{Sn, Ts} | Left], Buf, Size, Limit) ->
  #kcp_seg{conv = Conv, wnd = Wnd, una = Una} = Seg,
  Bin = ?KCP_SEG(Conv, ?KCP_CMD_ACK, 0, Wnd, Ts, Sn, Una, 0, <<>>, <<>>),
  {Buf2, Size2} = kcp_output(Socket, Key, Bin, Buf, Size, Limit),
  kcp_flush_ack2(Socket, Key, Seg, Left, Buf2, Size2, Limit).

%% Do not implement wnd probe right now
kcp_probe_wnd(_Socket, KCP, _Seg, Buf) -> {KCP, Buf}.

kcp_flush_wnd(_Socket, KCP = #kcp_pcb{probe = Probe}, _Seg, Buf)
    when Probe band ?KCP_ASK_TELL =:= 0 -> {KCP, Buf};
kcp_flush_wnd(Socket, KCP, Seg, {Buf, Size}) ->
  #kcp_pcb{key = Key, mtu = Mtu} = KCP,
  #kcp_seg{conv = Conv, wnd = Wnd, una = Una} = Seg,
  Bin = ?KCP_SEG(Conv, ?KCP_CMD_WINS, 0, Wnd, 0, 0, Una, 0, <<>>, <<>>),
  Buf2 = kcp_output(Socket, Key, Bin, Buf, Size, Mtu),
  {KCP, Buf2}.

%%kcp_flush_syncack(_Socket, KCP = #kcp_pcb{probe = Probe}, _Seg, Buf)
%%    when Probe band ?KCP_SYNC_ACK_SEND =:= 0 -> {KCP, Buf};
%%kcp_flush_syncack(Socket, KCP, Seg, {Buf, Size}) ->
%%  #kcp_pcb{key = Key, mtu = Mtu} = KCP,
%%  #kcp_seg{conv = Conv, wnd = Wnd, una = Una} = Seg,
%%  Bin = ?KCP_SEG(Conv, ?KCP_CMD_SYNC_ACK, 0, Wnd, 0, 0, Una, 0, <<>>, <<>>),
%%  Buf2 = kcp_output(Socket, Key, Bin, Buf, Size, Mtu),
%%  {KCP, Buf2}.
%%
%%kcp_flush_sync(_Socket, KCP = #kcp_pcb{probe = Probe}, _Seg, Buf)
%%    when Probe band ?KCP_SYNC_SEND =:= 0 -> {KCP, Buf};
%%kcp_flush_sync(Socket, KCP, Seg, {Buf, Size}) ->
%%  #kcp_pcb{key = Key, mtu = Mtu} = KCP,
%%  #kcp_seg{conv = Conv, wnd = Wnd, una = Una} = Seg,
%%  Bin = ?KCP_SEG(Conv, ?KCP_CMD_SYNC, 0, Wnd, 0, 0, Una, 0, <<>>, <<>>),
%%  Buf2 = kcp_output(Socket, Key, Bin, Buf, Size, Mtu),
%%  {KCP, Buf2}.

kcp_flush_data(Socket, KCP, Seg, Buf) ->
  #kcp_pcb{snd_wnd = SWnd, rmt_wnd = RWnd, nocwnd = NoCwnd, cwnd = CWnd} = KCP,
  CalWnd = lists:min([SWnd, RWnd]),
  CalWnd2 = case NoCwnd =:= 0 of
    true -> lists:min([CWnd, CalWnd]);
    false -> CalWnd
  end,
  KCP2 = sndque_to_sndbuf(KCP, Seg, CalWnd2),
  FastResent = case KCP2#kcp_pcb.fastresend > 0 of
    true  -> KCP2#kcp_pcb.fastresend;
    false -> 16#FFFFFFFF
  end,
  RtoMin = case KCP2#kcp_pcb.nodelay == 0 of
    true  -> KCP2#kcp_pcb.rx_rto bsr 3;
    false -> 0
  end,
  {KCP3, Buf2} = kcp_flush_data2(Socket, KCP2, Buf, FastResent, RtoMin, CalWnd2),
  {KCP3, Buf2}.

kcp_flush_data2(Socket, KCP, Buf, FastResent, RtoMin, CWnd) ->
  #kcp_pcb{snd_buf = SndBuf} = KCP,
  {KCP2, Buf2} = kcp_flush_data3(Socket, SndBuf, ditch_buffer:first(SndBuf), FastResent,
    RtoMin, KCP, Buf, false, false, CWnd),
  {KCP2, Buf2}.

kcp_flush_data3(_Socket, SndBuf, ?LAST_INDEX, FastResent, _RtoMin, KCP, Buf, Change, Lost, CalcWnd) ->
  KCP2 = case Change of
    false -> KCP#kcp_pcb{snd_buf = SndBuf};
    true  ->
      #kcp_pcb{snd_nxt = SndNxt, snd_una = SndUna, cwnd = CWnd, mss = Mss} = KCP,
      Thresh2 = case (SndNxt - SndUna) div 2 of
        V when V < ?KCP_THRESH_MIN -> ?KCP_THRESH_MIN;
        V -> V
      end,
      KCP#kcp_pcb{snd_buf = SndBuf, cwnd = Thresh2 + FastResent, incr = CWnd * Mss, ssthresh = Thresh2}
  end,
  KCP3 = case Lost of
    true ->
      Thresh3 = lists:max([?KCP_THRESH_MIN, CalcWnd div 2]),
      KCP2#kcp_pcb{ssthresh = Thresh3, cwnd = 1, incr = KCP2#kcp_pcb.mss};
    false -> KCP2
  end,
  KCP4 = case KCP3#kcp_pcb.cwnd < 1 of
    true -> KCP3#kcp_pcb{cwnd = 1, incr = KCP3#kcp_pcb.mss};
    false -> KCP3
  end,
  {KCP4, Buf};
kcp_flush_data3(Socket, SndBuf, Idx, FastResent, RtoMin, KCP, {Buf, Size}, Change, Lost, CWnd) ->
  #kcp_pcb{current = Current, rx_rto = Rto, nodelay = NoDelay, mtu = Mtu, key = Key} = KCP,
  Next = ditch_buffer:next(Idx, SndBuf),
  case ditch_buffer:get_data(Idx, SndBuf) of
    undefined ->
      kcp_flush_data3(Socket, SndBuf, Next, FastResent, RtoMin, KCP, {Buf, Size}, Change, Lost, CWnd);
    Seg = #kcp_seg{xmit = Xmit, resendts = ResentTs, fastack = FastAck, rto = SRto} ->
      {Send, Lost2, Change2, Seg2} = if
        Xmit =:= 0 ->
          S2 = Seg#kcp_seg{xmit = Xmit + 1, rto = Rto, resendts = Current + Rto + RtoMin},
          {true, false or Lost, false or Change, S2};
        Current >= ResentTs ->
          SRto2 = case NoDelay =:= 0 of
            true  -> SRto + Rto;
            false -> SRto + Rto div 2
          end,
          S2 = Seg#kcp_seg{xmit = Xmit + 1, rto = SRto2, resendts = Current + SRto2},
          {true, true or Lost, false or Change, S2};
        FastAck > FastResent ->
          S2 = Seg#kcp_seg{xmit = Xmit + 1, fastack = 0, resendts = Current + Rto},
          {true, false or Lost, true or Change, S2};
        true -> {false, false or Lost, false or Change, Seg}
      end,

      SndBuf2 = case Send of
        true  -> ditch_buffer:set_data(Idx, Seg2, SndBuf);
        false -> SndBuf
      end,
      case Send =:= true of
        true ->
          #kcp_seg{conv = Conv, frg = Frg, wnd = Wnd, ts = Ts, sn = Sn, una = Una, len = Len, data = Data} = Seg2,
          Bin = ?KCP_SEG(Conv, ?KCP_CMD_PUSH, Frg, Wnd, Ts, Sn, Una, Len, Data, <<>>),
          {Buf2, Size2} = kcp_output(Socket, Key, Bin, Buf, Size, Mtu),
          kcp_flush_data3(Socket, SndBuf2, Next, FastResent, RtoMin, KCP, {Buf2, Size2}, Change2, Lost2, CWnd);
        false ->
          kcp_flush_data3(Socket, SndBuf2, Next, FastResent, RtoMin, KCP, {Buf, Size}, Change2, Lost2, CWnd)
      end
  end.

sndque_to_sndbuf(KCP, Seg, CWnd) ->
  #kcp_pcb{snd_queue = SndQue, snd_buf = SndBuf, snd_nxt = SndNxt, snd_una = SndUna} = KCP,
  case ditch_queue:len(SndQue) =:= 0 of
    true -> KCP;
    false -> sndque_to_sndbuf2(SndNxt, SndUna + CWnd, Seg, SndQue, SndBuf)
  end.
sndque_to_sndbuf2(SndNxt, Limit, _Seg, SndQue, SndBuf) when SndNxt >= Limit ->
  {SndNxt, SndQue, SndBuf};
sndque_to_sndbuf2(SndNxt, Limit, Seg, SndQue, SndBuf) ->
  #kcp_seg{frg = Frg, len = Len, data = Data} = ditch_queue:get(SndQue),
  SndQue2 = ditch_queue:drop(SndQue),
  NSeg = Seg#kcp_seg{cmd = ?KCP_CMD_PUSH, sn = SndNxt, frg = Frg, len = Len, data = Data},
  SndBuf2 = ditch_buffer:append_tail(NSeg, SndBuf),
  sndque_to_sndbuf2(SndNxt + 1, Limit, Seg, SndQue2, SndBuf2).


kcp_output(Socket, Key, Bin, Buf, Size, Limit) ->
  {Buf2, Size2} = case Size + ?KCP_OVERHEAD > Limit of
    true ->
      Data = util:binary_join(Buf),
      kcp_output2(Socket, Key, Data),
      {[], 0};
    false ->
      {Buf, Size}
  end,
  Size3 = Size2 + byte_size(Bin),
  Buf3 = [Bin | Buf2],
  {Buf3, Size3}.

kcp_output2(_Socket, _Key, <<>>) -> ok;
kcp_output2(Socket, {IP, Port}, Data) ->
  case gen_udp:send(Socket, IP, Port, Data) of
    ok -> ok;
    {error, Reason} ->
      ?ERRORLOG("send udp data to ~p failed with reason ~p", [{IP, Port}, Reason]),
      {error, Reason}
  end.

dump_kcp(#kcp_pcb{snd_buf = SndBuf, rcv_buf = RcvBuf}) ->
  NSndBuf = ditch_buffer:unused(SndBuf),
  NRcvBuf = ditch_buffer:unused(RcvBuf),
  ?DEBUGLOG("kcp state ~p", [{NSndBuf, NRcvBuf}]).