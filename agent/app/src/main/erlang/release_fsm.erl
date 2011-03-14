-module(release_fsm).
-behavior(gen_fsm).
-export([init/1, start_link/2, handle_info/3, handle_event/3,
	 handle_sync_event/4, code_change/4, terminate/3]).
-export([connecting/2, binding/2, disconnected_binding/2, upgrading_binding/2,
	 running/2, reconnecting/2]).

-include_lib("kernel/include/file.hrl").

-record(paths, {runtime}).
-record(state, {rel, vsn, paths, facts, config,
		cpid, cname, cnode, session, rpid,
		tmoref
	       }).

start_link(Rel, Path) ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, [Rel, Path], []).

init([Rel, Path]) ->
    Facts = facter:get_facts(),

    [Name, Host] = string:tokens(atom_to_list(node()), "@"),

    ClientName = Name ++ "-client",
    ClientNode = list_to_atom(ClientName ++ "@" ++ Host),

    % Ensure that the client is not already running
    case net_adm:ping(ClientNode) of
	pong ->
	    rpc:call(ClientNode, init, stop, []);
	_ ->
	    void
    end,

    RuntimeDir = filename:join([Path, "runtime"]),

    case filelib:is_dir(RuntimeDir) of
	true ->
	    % make sure we dont have an old runtime hanging around
	    {ok, Files} = file:list_dir(RuntimeDir), 
	    target_system:remove_all_files(RuntimeDir, Files);
	false ->
	    ok = filelib:ensure_dir(RuntimeDir)
    end,

    error_logger:info_msg("Starting with facts: ~p~n", [Facts]),
    Paths = #paths{runtime=RuntimeDir},
    {ok, connecting, #state{rel=Rel, paths=Paths, facts=Facts,
			    cname=ClientName, cnode=ClientNode}}.

connecting({controller, connected, CPid}, State) ->
    TmpFile = tempfile(),

    try
	{ok, Session} = controller_api:negotiate(CPid),
	{ok, Vsn} = controller_api:join(Session,
					State#state.facts,
					State#state.rel),
 
	{ok, Vsn, Config, IDev} =
	    controller_api:download_release(Session),
	ok = remote_copy(IDev, TmpFile),
	
	RelName = relname(State#state.rel, Vsn),
	RuntimeDir = State#state.paths#paths.runtime,
	ok = target_system:install(RelName, RuntimeDir, TmpFile),

	BootFile = filename:join([RuntimeDir, "releases", Vsn, "start"]),
	Cmd = filename:join([RuntimeDir, "bin", "erl"]) ++ 
	    " -boot " ++ BootFile ++
	    " -noinput" ++
	    " -sname " ++ State#state.cname ++
	    " " ++ Config,

	error_logger:info_msg("Launching ~s~n", [Cmd]),

	S = self(),
	RPid = spawn_link(fun() ->
				 Result = os_cmd:os_cmd(Cmd),
				 gen_fsm:send_event(S, {release_stopped, Result})
			 end),

	NewState = State#state{cpid=CPid, session=Session,
		     vsn=Vsn, config=Config, rpid=RPid},
	case bind(NewState) of
	    true ->
		{next_state, running, NewState};
	    false ->
		{next_state, binding, start_timer(500, NewState)}
	end
    after
	ok = file:delete(TmpFile)
    end.

binding({release_stopped, _Data}, State) ->
    gen_fsm:cancel_timer(State#state.tmoref),
    {stop, normal, State};
binding({timeout, _, bind}, State) ->
    case bind(State) of
	true ->
	    {next_state, running, State};
	false ->
	    {next_state, binding, start_timer(1000, State)}
    end;
binding({hotupdate, Vsn}, State) ->
    if
	Vsn =/= State#state.vsn ->
	    {ok, upgrade_binding, State};
	true ->
	    {ok, binding, State}
    end;
binding({controller, disconnected}, State) ->
    {next_state, disconnected_binding,
     State#state{cpid=undefined, session=undefined}}.

disconnected_binding({release_stopped, _Data}, State) ->
    gen_fsm:cancel_timer(State#state.tmoref),
    {stop, normal, State};
disconnected_binding({timeout, _, bind}, State) ->
    case bind(State) of
	true ->
	    {next_state, reconnecting, State};
	false ->
	    {next_state, disconnected_binding, start_timer(1000, State)}
    end;
disconnected_binding({controller, connected, CPid}, State) ->
    {ok, Session} = controller_api:negotiate(CPid),
    {ok, Vsn} = controller_api:join(Session, State#state.facts, State#state.rel),

    NewState = State#state{cpid=CPid, session=Session},
    if
	Vsn =:= State#state.vsn ->
	    {ok, binding, NewState};
	true ->
	    {ok, upgrading_binding, NewState}
    end.

upgrading_binding({release_stopped, _Data}, State) ->
    gen_fsm:cancel_timer(State#state.tmoref),
    {stop, normal, State};
upgrading_binding({timeout, _, bind}, State) ->
    case bind(State) of
	true ->
	    NewState = upgrade(State),
	    {next_state, running, NewState};
	false ->
	    {next_state, upgrading_binding, start_timer(1000, State)}
    end;
upgrading_binding({controller, disconnected}, State) ->
    {next_state, disconnected_binding,
     State#state{cpid=undefined, session=undefined}}.

running({release_stopped, _Data}, State) ->
    {stop, normal, State};
running({hotupdate, Vsn}, State) ->
    NewState = if
		   Vsn =/= State#state.vsn ->
		       upgrade(State);
		   true ->
		       State
	       end,
    {next_state, running, NewState};
running({controller, disconnected}, State) ->
    {next_state, reconnecting, State#state{cpid=undefined, session=undefined}}.

reconnecting({release_stopped, _Data}, State) ->
    {stop, normal, State};
reconnecting({controller, connected, Pid}, State) ->
    {ok, Session} = controller_api:negotiate(Pid),
    {ok, Vsn} = controller_api:join(Session, State#state.facts, State#state.rel),

    {ok, running, State#state{cpid=Pid, session=Session}}.

handle_event(Event, _StateName, _State) ->
    throw({"Unexpected event", Event}).

handle_sync_event(_Event, _From, StateName, State) ->
    {reply, {error, einval}, StateName, State}.

handle_info(Info, StateName, State) ->
    gen_fsm:send_event(self(), Info),
    {next_state, StateName, State}.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(Reason, running, State) ->
    rpc:call(State#state.cnode, init, stop, []),
    error_logger:info_msg("Terminate: ~p~n", [Reason]);
terminate(Reason, _StateName, _State) ->
    error_logger:info_msg("Terminate: ~p~n", [Reason]),
    void.

start_timer(Tmo, State) ->
    TmoRef = gen_fsm:start_timer(Tmo, bind),
    State#state{tmoref=TmoRef}.

upgrade(State) ->
    % FIXME
    State.

bind(State) ->
    error_logger:info_msg("Binding to ~p....~n", [State#state.cnode]), 
    case net_adm:ping(State#state.cnode) of
	pong ->
	    error_logger:info_msg("Binding complete~n", []),
	    gen_event:notify({global, edist_event_bus},
			     {online, State#state.cnode}),
	    true;
	_ ->
	    false
    end.

relname(Rel, Vsn) ->
    Rel ++ "-" ++ Vsn.

remote_copy(IDev, File) ->
    {ok, ODev} = file:open(File, [write, binary]),
    {ok, _} = file:copy(IDev, ODev),
    file:close(ODev),
    controller_api:close_stream(IDev).   

os_cmd(Cmd) ->
    [Tmp | _ ] = string:tokens(os_cmd:os_cmd(Cmd), "\n"),
    Tmp.

tempfile() -> 
    os_cmd("mktemp").
