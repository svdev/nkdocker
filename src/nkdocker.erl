%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Main management module.
-module(nkdocker).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export_type([conn_opts/0, create_opts/0, async_msg/0]).

-include_lib("nklib/include/nklib.hrl").
-include("nkdocker.hrl").

-export([start_link/1, start/1, stop/1, finish_async/2]).
-export([version/1, info/1, ping/1, events/1, events/2, login/4, login/5]).
-export([attach/2, attach/3, attach_send/3, commit/2, commit/3, cp/4, create/3, diff/2,
   		 export/3, inspect/2, kill/2, kill/3, logs/2, logs/3, pause/2, ps/1, ps/2, 
   		 rename/3, restart/2, restart/3, rm/2, rm/3, start/2, resize/4,
   		 stats/2, stop/2, stop/3, top/2, top/3, unpause/2, wait/2, wait/3]).
-export([images/1, images/2, build/2, build/3, create_image/2, history/2, push/3, 
	     tag/3, inspect_image/2, search/2, rmi/2, rmi/3, get_image/3, get_images/3,
	     load/2]).
-export([exec_create/3, exec_create/4, exec_start/2, exec_start/3, exec_inspect/2,
	     exec_resize/4]).
-import(nklib_util, [to_binary/1]).


-define(HUB, <<"https://index.docker.io/v1/">>).
-define(TIMEOUT, 180000).



%% ===================================================================
%% Types
%% ===================================================================

-type text() :: string() | binary().

-type conn_opts() ::
	#{	
		host => text(),					% Default "127.0.0.1"
		port => inet:port_number(),		% Default 2376
		proto => tcp | tls,				% Default tcp
		certfile => text(),
		keyfile => text(),
		idle_timeout => integer()		% Msecs, default 5000
	}.

-type docker_device() ::
	text() | 						% Host
	{text(), text()} | 				% Host, Container
	{text(), text(), text()}.		% Host, Container, Perm

-type docker_port() :: inet:port_number() | {inet:port_number(), tcp|udp}.

-type docker_publish() ::
	docker_port() |												% Container
	{docker_port() | inet:port_number()} |						% Container, Host
	{docker_port() | inet:port_number(), inet:ip_address()}.	% Container, Host, Ip


-type create_opts() ::
	#{
		attach => [stdin | stdout | stderr],
		add_hosts => [{Host::text(), Ip::inet:ip_address()}],
		cap_add => [text()], 
		cap_drop => [text()], 
		cidfile => text(),
		cmds => [text()], 
		cpu_set => text(),
		cpu_shares => pos_integer(),
		devices => [docker_device()],	
		dns => [text()],
		dns_search => [text()],
		env => [{text(), text()}],
		entrypoints => [text()],
		expose => [docker_port()],
		hostname => text(),
		interactive => boolean(),
		labels => [{Key::text(), Val::text()}],
		links => [{Cont::text(), Alias::text()}],	
		lxc_confs => [{text(), text()}],
		mac_address => text(),
		memory => pos_integer(),
		memory_swap => -1 | pos_integer(),
		net => none | bridge | host | text(),
		publish_all => boolean(),
		publish => [docker_publish()],
		pid => text(),
		privileged => boolean(),
		read_only => boolean(),
		restart => always | on_failure | {on_failure, integer()},
		security_opts => [text()],
		tty => boolean(),
		user => text(),
		volumes => [Cont::text() | {Host::text(), Cont::text()}],
		volumes_from => [text()],
		workdir => text()
	}.
	

-type error() ::
	{not_modified | bad_parameter | not_found | not_running | conflict |
	server_error | pos_integer(), binary()}.

-type async_msg() ::
	{nkdocker, reference(), binary()|map()|{stop, term()}}.

-type event_type() ::
	create | destroy | die | exec_create | exec_start | export | kill | oom | 
	pause | restart | start | stop | unpause | untag | delete.


%% ===================================================================
%% Server functions
%% ===================================================================


%% @doc Starts and links new docker connection
-spec start_link(conn_opts()) ->
	{ok, pid()} | {error, term()}.

start_link(Opts) ->
	nkdocker_server:start_link(Opts).


%% @doc Starts a new docker connection
-spec start(conn_opts()) ->
	{ok, pid()} | {error, term()}.

start(Opts) ->
	nkdocker_server:start(Opts).


%% @doc Stops a docker connection
-spec stop(pid()) ->
	ok.

stop(Pid) ->
	nkdocker_server:stop(Pid).


%% @doc Finishes an asynchronous command (see logs/3)
-spec finish_async(pid(), reference()) ->
	{ok, pid()} | {error, term()}.

finish_async(Pid, Ref) ->
	nkdocker_server:finish(Pid, Ref).



%% ===================================================================
%% Common Docker Functions
%% ===================================================================


%% @doc Shows docker daemon version.
%% It tries to reuse a previous connection.
-spec version(pid()) ->
	{ok, map()} | {error, error()}.

version(Pid) ->
	get(Pid, <<"/version">>, #{}).


%% @doc Gets info about the docker daemon.
%% It tries to reuse a previous connection.
-spec info(pid()) ->
	{ok, map()} | {error, error()}.

info(Pid) ->
	get(Pid, <<"/info">>, #{}).


%% @doc Pings to the the docker daemon.
%% It tries to reuse a previous connection.
-spec ping(pid()) ->
	{ok, map()} | {error, error()}.

ping(Pid) ->
	case get(Pid, <<"/_ping">>, #{}) of
		{ok, <<"OK">>} -> ok;
		{error, Error} -> {error, Error}
	end.


%% @doc Equivalent to events(Pid, #{})
-spec events(pid()) ->
	{ok, reference()} | {error, error()}.

events(Pid) ->
	events(Pid, #{}).


%% @doc Subscribe to docker events
%% If ok, a new referece will be returned, along with the connection's pid().
%% Each new docker event will be sent to the calling process as an async_msg().
%% Should the connection stop, a stop mesage will be sent.
%% You can use finish_async/2 to remove the subscription using the reference,
%% or nkpacket_connection:stop(ConnPid, normal) using the connection pid.
%% When the calling process dies, the connection is automatically removed.
-spec events(pid(), 
	#{
		filters => #{
			event => [event_type()],	% Receive only this event types
			image => text(),			% Only for this image
			container => text()			% Only for this container
		},
		since => text(),				% Since this time
		until => text()					% Up to this time
	}) ->
	{ok, reference(), pid()} | {error, error()}.

events(Pid, Opts) ->
	Path = make_path(<<"/events">>, get_filters(Opts), [filters, since, until]),
	Opts1 = Opts#{async=>true, force_new=>true, idle_timeout=>5000, refresh=>true},
	get(Pid, Path, Opts1).


%% @doc Equivalent to login(Pid, User, Pass, Email, ?HUB)
-spec login(pid(), text(), text(), text()) ->
	{ok, map()} | {error, error()}.

login(Pid, User, Pass, Email) ->
	login(Pid, User, Pass, Email, ?HUB).


%% @doc Logins to a repository hub to check credentials
-spec login(pid(), text(), text(), text(), text()) ->
	ok | {error, error()}.

login(Pid, User, Passwd, Email, Repo) ->
	Spec1 = #{
		username => to_binary(User),
		password => to_binary(Passwd),
		email => to_binary(Email),
		serveraddress => to_binary(Repo)
	},
	case post(Pid, <<"/auth">>, Spec1, #{force_new=>true}) of
		{ok, _} -> ok;
		{error, Error} -> {error, Error}
	end.



%% ===================================================================
%% Container Docker Functions
%% ===================================================================


%% @doc Equivalent to pid(Pid, #{})
-spec ps(pid()) ->
	{ok, [map()]} | {error, error()}.

ps(Pid) ->
	ps(Pid, #{}).


%% @doc List containers.
%% It tries to reuse a previous connection.
 -spec ps(pid(), 
	#{
		all => boolean(),				%
		before => text(),				% Create before this Id
		filters => #{
			status => [restarting|running|paused|exited],
			exited => Code::integer()
		},
		limit => integer(),				%
		size => boolean(),				% Show sizes
		since => text()					% Created since this Id
	}) ->
	{ok, [map()]} | {error, error()}.

ps(Pid, Opts) ->
	UrlOpts = [all, before, filters, limit, size, since],
	Path = make_path(<<"/containers/json">>, get_filters(Opts), UrlOpts),
	get(Pid, Path, #{}).


%% @doc Create a container
-spec create(pid(), text(), create_opts() |	#{name => text()}) ->
	{ok, map()} | {error, error()}.

create(Pid, Image, Opts) ->
	Path = make_path(<<"/containers/create">>, Opts, [name]),
	case nkdocker_opts:create_spec(Opts#{image=>Image}) of
		{ok, Spec} ->
			post(Pid, Path, Spec, #{force_new=>true});
		{error, Error} ->
			{error, Error}
	end.


%% @doc Inspect a container.
%% It tries to reuse a previous connection.
-spec inspect(pid(), text()) ->
	{ok, map()} | {error, error()}.

inspect(Pid, Id) ->
	Path = list_to_binary([<<"/containers/">>, Id, <<"/json">>]),
	get(Pid, Path, #{}).


%% @doc Equivalent to top(Pid, Container, #{})
-spec top(pid(), text()) ->
	{ok, map()} | {error, error()}.

top(Pid, Container) ->
	top(Pid, Container, #{}).


%% @doc List processes running inside a container.
%% It tries to reuse a previous connection.
-spec top(pid(), text(), #{ps_args=>text()}) ->
	{ok, map()} | {error, error()}.

top(Pid, Container, Opts) ->
	Path1 = list_to_binary([<<"/containers/">>, Container, <<"/top">>]),
	Path2 = make_path(Path1, Opts, [ps_args]),
	get(Pid, Path2, #{}).


%% @doc Equivalent to logs(Pid, Container, #{stdout=>true})
-spec logs(pid(), text()) ->
	{ok, binary()} | {error, error()}.

logs(Pid, Container) ->
	logs(Pid, Container, #{stdout=>true}).


%% @doc Get stdout and stderr logs from the container id
%% You must select on stream at least (stdin, stdout or stderr).
%% If you use the 'async' option, a reference() and connection pid() will be returned, 
%% and new data will be sent to the calling process a async_mgs() messages.
%% (see events/2)
%% If you use the 'follow' option, the connection will remain opened 
%% (async is automatically selected)
-spec logs(pid(), text(),
	#{
		async => boolean(),
		follow => boolean(),
		stdout => boolean(),
		stderr => boolean(),
		timestamps => boolean(),
		tail => text()
	}) ->
	{ok, binary()} | {ok, reference(), pid()} | {error, error()}.

logs(Pid, Container, Opts) ->
	Path1 = list_to_binary([<<"/containers/">>, Container, <<"/logs">>]),
	UrlOpts = [follow, timestamps, stdout, stderr, tail],
	Path2 = make_path(Path1, Opts, UrlOpts),
	case Opts of 
		#{follow:=true} ->
			get(Pid, Path2, #{async=>true, idle_timeout=>5000, refresh=>true});
		#{async:=true} ->
			get(Pid, Path2, #{async=>true});
		_ ->
			get(Pid, Path2, #{force_new=>true})
	end.


%% @doc Inspect changes on a container's filesystem.
%% It tries to reuse a previous connection.
-spec diff(pid(), text()) ->
	{ok, [map()]} | {error, error()}.

diff(Pid, Container) ->
	Path = list_to_binary([<<"/containers/">>, Container, <<"/changes">>]),
	get(Pid, Path, #{}).


%% @doc Export the contents of container id to a TAR file.
-spec export(pid(), text(), text()) ->
	ok | {error, error()}.

export(Pid, Container, File) ->
	Path = list_to_binary([<<"/containers/">>, Container, <<"/export">>]),
	Redirect = nklib_util:to_list(File),
	case get(Pid, Path, #{redirect=>Redirect, timeout=>?TIMEOUT}) of
		{ok, <<>>} -> ok;
		{error, Error} -> {error, Error}
	end.


%% @doc Get container stats based on resource usage.
%% A reference and connection pid will be returned (see events/2).
-spec stats(pid(), text()) ->
	{ok, reference(), pid()} | {error, error()}.

stats(Pid, Container) ->
	Path = list_to_binary([<<"/containers/">>, Container, <<"/stats">>]),
	get(Pid, Path, #{async=>true, idle_timeout=>5000}).


%% @doc Resize the TTY for container with id. 
%% The container must be restarted for the resize to take effect.
%% It tries to reuse a previous connection.
-spec resize(pid(), text(), integer(), integer()) ->
	ok | {error, error()}.

resize(Pid, Container, W, H) ->
	Path1 = list_to_binary([<<"/containers/">>, Container, <<"/resize">>]),
	Path2 = make_path(Path1, #{h=>H, w=>W}, [h, w]),
	case post(Pid, Path2, #{}) of
		{ok, <<>>} -> ok;
		{error, Error} -> {error, Error}
	end.


%% @doc Start a container
-spec start(pid(), text()) ->
	ok | {error, error()}.

start(Pid, Container) ->
	Path = list_to_binary([<<"/containers/">>, Container, <<"/start">>]),
	case post(Pid, Path, #{force_new=>true}) of
		{ok, _} -> ok;
		{error, Error} -> {error, Error}
	end.


%% @doc Equivalent to stop(Pid, Container, #{})
-spec stop(pid(), text()) ->
	ok | {error, error()}.

stop(Pid, Container) ->
	stop(Pid, Container, #{}).


%% @doc Stops a container
%% Can specify the maximum time (in seconds) before killing it.
-spec stop(pid(), text(), #{t=>pos_integer()}) ->
	ok | {error, error()}.

stop(Pid, Container, Opts) ->
	Path1 = list_to_binary([<<"/containers/">>, Container, <<"/stop">>]),
	Path2 = make_path(Path1, Opts, [t]),
	Timeout = 2 * maps:get(t, Opts, ?TIMEOUT),
	case post(Pid, Path2, #{force_new=>true, timeout=>Timeout}) of
		{ok, _} -> ok;
		{error, Error} -> {error, Error}
	end.


%% @doc Equivalent to restart(Pid, Text, #{})
-spec restart(pid(), text()) ->
	ok | {error, error()}.

restart(Pid, Container) ->
	restart(Pid, Container, #{}).


%% @doc Restart a container
%% Can specify the maximum time (in seconds) before killing it
-spec restart(pid(), text(), #{t=>pos_integer()}) ->
	ok | {error, error()}.

restart(Pid, Container, Opts) ->
	Path1 = list_to_binary([<<"/containers/">>, Container, <<"/restart">>]),
	Path2 = make_path(Path1, Opts, [t]),
	Timeout = 2 * maps:get(t, Opts, ?TIMEOUT),
	case post(Pid, Path2, #{force_new=>true, timeout=>Timeout}) of
		{ok, _} -> ok;
		{error, Error} -> {error, Error}
	end.


%% @doc Equivalent to kill(Pid, Container, #{})
-spec kill(pid(), text()) ->
	ok | {error, error()}.

kill(Pid, Container) ->
	kill(Pid, Container, #{}).


%% @doc Kill a container
%% Can specify the signal to send
-spec kill(pid(), text(), #{signal=>integer()|text()}) ->
	ok | {error, error()}.

kill(Pid, Container, Opts) ->
	Path1 = list_to_binary([<<"/containers/">>, Container, <<"/kill">>]),
	Path2 = make_path(Path1, Opts, [signal]),
	case post(Pid, Path2, #{force_new=>true}) of
		{ok, _} -> ok;
		{error, Error} -> {error, Error}
	end.


%% @doc Rename a container with a new name.
%% It tries to reuse a previous connection.
-spec rename(pid(), text(), text()) ->
	ok | {error, error()}.

rename(Pid, Id, Name) ->
	Path1 = list_to_binary([<<"/containers/">>, Id, <<"/rename">>]),
	Path2 = make_path(Path1, #{name=>Name}, [name]),
	case post(Pid, Path2, #{}) of
		{ok, _} -> ok;
		{error, Error} -> {error, Error}
	end.


%% @doc Pause a container.
%% It tries to reuse a previous connection.
-spec pause(pid(), text()) ->
	ok | {error, error()}.

pause(Pid, Container) ->
	Path = list_to_binary([<<"/containers/">>, Container, <<"/pause">>]),
	case post(Pid, Path, #{}) of
		{ok, _} -> ok;
		{error, Error} -> {error, Error}
	end.


%% @doc Unpause a container.
%% It tries to reuse a previous connection.
-spec unpause(pid(), text()) ->
	ok | {error, error()}.

unpause(Pid, Container) ->
	Path = list_to_binary([<<"/containers/">>, Container, <<"/unpause">>]),
	case post(Pid, Path, #{}) of
		{ok, _} -> ok;
		{error, Error} -> {error, Error}
	end.


%% @doc Equivalent to attach(Pid, Container, #{stream=>true, stdin=>true, stdout=>true}
-spec attach(pid(), text()) ->
	{ok, reference()} | {error, error()}.

attach(Pid, Container) ->
	attach(Pid, Container, #{stream=>true, stdin=>true, stdout=>true}).


%% @doc Attach to a container input/output/error
%% When using 'async', a reference is returned (see events/2)
%% When using 'stream' the connection reamins opened (async is automatically selected),
%% and you can send commands using attach_send/3
%% When created with the TTY setting, the stream is the raw data from the process 
%% PTY and client's stdin. When the TTY is disabled, then the stream is multiplexed
%% to separate stdout and stderr.
%% (received messages will be {stdin|stdout|stderr, binary()})
-spec attach(pid(), text(), 
	#{
		async => boolean(),
		stream => boolean(),		% Do streaming
		logs => boolean(), 			% Return logs
		stdin => boolean(),			% If stream, attach to stdin
		stdout => boolean(),		% If logs, return stdout log. If stream, attach
		stderr => boolean(),		% If logs, return stderr log. If stream, attach
		timeout => pos_integer()	% Timeout before closing the connection (secs)
	}) ->
	{ok, binary} | {ok, reference(), pid()} | {error, error()}.

attach(Pid, Container, Opts) ->
	Path1 = list_to_binary([<<"/containers/">>, Container, <<"/attach">>]),
	UrlOpts = [logs, stream, stdin, stdout, stderr],
	Path2 = make_path(Path1, Opts, UrlOpts),
	case Opts of
		#{stream:=true} ->
			Timeout = maps:get(timeout, Opts, 3600000),
			post(Pid, Path2, #{async=>true, timeout=>Timeout});
		#{async:=true} ->
			post(Pid, Path2, #{async=>true});
		_ ->
			post(Pid, Path2, #{force_new=>true})
	end.


%% @doc Sends text to an attached 'stream' session
-spec attach_send(pid(), reference(), iolist()) ->
	ok.

attach_send(Pid, Ref, Data) ->
	nkdocker_server:data(Pid, Ref, Data).


%% @doc Equivalent to wait(Pid, Container, 60000)
-spec wait(pid(), text()) ->
	{ok, integer()} | {error, error()}.

wait(Pid, Container) ->
	wait(Pid, Container, 60000).


%% @doc Waits for a container to stop, returning the exit code
-spec wait(pid(), text(), integer()) ->
	{ok, integer()} | {error, error()}.

wait(Pid, Container, Timeout) ->
	Path = list_to_binary([<<"/containers/">>, Container, <<"/wait">>]),
	case post(Pid, Path, #{force_new=>true, timeout=>Timeout}) of
		{ok, #{<<"StatusCode">> := Code}} -> {ok, Code};
		{error, Error} -> {error, Error}
	end.


%% @doc Equivalent to rm(Pid, Container, #{})
-spec rm(pid(), text()) ->
	ok | {error, error()}.

rm(Pid, Container) ->
	rm(Pid, Container, #{}).


%% @doc Removes a container
-spec rm(pid(), text(), 
	#{
		force => boolean(),			% Kill the container before removing
		v => boolean()				% Remove associated volumes
	}) ->
	ok | {error, error()}.

rm(Pid, Container, Opts) ->
	Path1 = list_to_binary([<<"/containers/">>, Container]),
	Path2 = make_path(Path1, Opts, [force, v]),
	case del(Pid, Path2, #{force_new=>true}) of
		{ok, <<>>} -> ok;
		{error, Error} -> {error, Error}
	end.


%% @doc Copy files or folders from a container to a TAR file
-spec cp(pid(), text(), text(), text()) ->
	ok | {error, error()}.

cp(Pid, Container, ContPath, File) ->
	Path = list_to_binary([<<"/containers/">>, Container, <<"/copy">>]),
	Body = #{'Resource' => to_binary(ContPath)},
	Redirect = nklib_util:to_list(File),
	case post(Pid, Path, Body, #{redirect=>Redirect}) of
		{ok, <<>>} -> ok;
		{error, Error} -> {error, Error}
	end.



%% ===================================================================
%% Images Docker Functions
%% ===================================================================


%% @doc Equivalent to images(Pid, #{})
-spec images(pid()) ->
	{ok, [map()]} | {error, error()}.

images(Pid) ->
	images(Pid, #{}).


%% @doc List images.
%% It tries to reuse a previous connection.
-spec images(pid(), 
	#{
		all => boolean(),
		filters => #{dangling => true}
	}) ->
	{ok, [map()]} | {error, error()}.

images(Pid, Opts) ->
	Path = make_path(<<"/images/json">>, get_filters(Opts), [all, filters]),
	get(Pid, Path, #{}).


%% @doc Equivalent to build(Path, TarBin, #{}).
-spec build(pid(),iolist()) ->
	{ok, [map()]} | {error, error()}.

build(Pid, TarBin) ->
	build(Pid, TarBin, #{}).


%% @doc Build an image from a Dockerfile
%% The TarBin must be a binary with a TAR archive format, compressed with 
%% one of the following algorithms: identity (no compression), gzip, bzip2, xz.
%% The archive must include a build instructions file, typically called Dockerfile
%% at the root of the archive. The dockerfile parameter may be used to specify 
%% a different build instructions file by having its value be the path to 
%% the alternate build instructions file to use.
%% The archive may include any number of other files, which will be accessible 
%% in the build context (See the ADD build command).
%% If you the 'async' option, a reference and connection pid will be returned
%% (see events/2).
-spec build(pid(), binary(), 
	#{
		async => boolean(),		% See description for logs/3
		dockerfile => text(),	% path within the build context to the Dockerfile
		t => text(), 			% repository name (and optionally a tag)
		remote => text(),		% git or HTTP/HTTPS URI build source
		q => binary(), 			% suppress verbose build output
		nocache => boolean(),   % do not use the cache when building the image
		pull => boolean(), 		% attempt to pull the image even if exists locally
		rm => boolean(),		% remove intermediate containers (default)
		forcerm => boolean(),	% always remove intermediate containers (includes rm)
		timeout => integer(),	% time to wait for sync requests
		username => text(),		% 
		password => text(),		% Use this info to log to a remote
		email => text(),		% registry to pull
		serveraddress => text() %
	}) ->
	{ok, [map()]} | {ok, reference(), pid()} | {error, error()}.

build(Pid, TarBin, Opts) ->
	UrlOpts = [dockerfile, t, remote, q, nocache, pull, rm, forcerm],
	Path = make_path(<<"/build">>, Opts, UrlOpts),
	PostOpts1 = #{
		async => maps:get(async, Opts, false),
		force_new => true, 
		headers => [{<<"content_type">>, <<"application/tar">>}],
		timeout => maps:get(timeout, Opts, ?TIMEOUT)
	},
	PostOpts2 = add_authconfig(Opts, PostOpts1),
	post(Pid, Path, TarBin, PostOpts2).


%% @doc Create an image, either by pulling it from the registry or by importing it
%% If you the 'async' option, a reference and connection pid will be returned
%% (see events/2).
-spec create_image(pid(), 
	#{
		async => boolean(),		% See description for logs/2
		fromImage => text(),	% name of the image to pull
		fromSrc => text(),		% source to import
		repo => text(),			% 
		tag => text(),			%
		registry => text(),		% the registry to pull from
		username => text(),		% Use this info to log to a remote
		password => text(),		% registry to pull
		email => text(),
		serveraddress => text()
	}) ->
	{ok, [map()]} | {ok, reference(), pid()} | {error, error()}.

create_image(Pid, Opts) ->
	UrlOpts = [fromImage, fromSrc, repo, tag, registry],
	Path = make_path(<<"/images/create">>, Opts, UrlOpts),
	PostOpts1 = #{
		async => maps:get(async, Opts, false),
		force_new => true, 
		headers => [{<<"content_type">>, <<"application/tar">>}],
		timeout => maps:get(timeout, Opts, ?TIMEOUT)
	},
	PostOpts2 = add_authconfig(Opts, PostOpts1),
	post(Pid, Path, PostOpts2).


%% @doc Inspect an image
%% It tries to reuse a previous connection.
-spec inspect_image(pid(), text()) ->
	{ok, map()} | {error, error()}.

inspect_image(Pid, Id) ->
	Path2 = list_to_binary([<<"/images/">>, Id, <<"/json">>]),
	get(Pid, Path2, #{}).


%% @doc Return the history of the image.
%% It tries to reuse a previous connection.
-spec history(pid(), text()) ->
	{ok, [map()]} | {error, error()}.

history(Pid, Image) ->
	Path = list_to_binary([<<"/images/">>, Image, <<"/history">>]),
	get(Pid, Path, #{}).


%% @doc Push an image on the registry
%% If you wish to push an image on to a private registry, that image 
%% must already have been tagged into a repository which references 
%% that registry host name and port.  This repository name should
%% then be used in the URL. This mirrors the flow of the CLI.
%% If you the 'async' option, a reference and connection pid will be returned
%% (see events/2).
-spec push(pid(), text(),
	#{
		async => boolean(),		% See description for logs/2
		tag => text(),			% the tag to associate with the image on the registry
		username => text(),		%
		password => text(),		% Use this info to log to a remote
		email => text(),		% registry to pull
		serveraddress => text() %
	}) ->
	{ok, [map()]} | {ok, reference(), pid()} | {error, error()}.

push(Pid, Name, Opts) ->
	UrlOpts = [tag],
	Path1 = list_to_binary([<<"/images/">>, Name, <<"/push">>]),
	Path2 = make_path(Path1, Opts, UrlOpts),
	PostOpts1 = #{
		async => maps:get(async, Opts, false),
		force_new => true, 
		timeout => maps:get(timeout, Opts, ?TIMEOUT)
	},
	PostOpts2 = add_authconfig(Opts, PostOpts1),
	post(Pid, Path2, PostOpts2).


%% @doc Tag an image into a repository.
%% It tries to reuse a previous connection.
-spec tag(pid(), text(),
	#{
		repo => text(),				% The repository to tag in
		force => boolean(),			%
		tag => text()				% The new tag name
	}) ->
	ok | {error, error()}.

tag(Pid, Name, Opts) ->
	UrlOpts = [repo, force, tag],
	Path1 = list_to_binary([<<"/images/">>, Name, <<"/tag">>]),
	Path2 = make_path(Path1, Opts, UrlOpts),
	case post(Pid, Path2, #{}) of
		{ok, _} -> ok;
		{error, Error} -> {error, Error}
	end.


%% @doc Equivalent to commit(Pid, Container, #{})
-spec commit(pid(), text()) ->
	{ok, Id::binary(), map()} | {error, error()}.

commit(Pid, Container) ->
	commit(Pid, Container, #{}).

%% @doc Create a new image from a container's changes
-spec commit(pid(), text(), 
	#{
		repo => text(), 
		tag => text(), 
		author => text(), 
		comment => text(),
		timeout => pos_integer()
	}) ->
	{ok, Id::binary(), map()} | {error, error()}.

commit(Pid, Container, Opts) ->
	UrlOpts = [container, repo, tag, author, comment],
	Path = make_path(<<"/commit">>, Opts#{container=>Container}, UrlOpts), 
	case nkdocker_opts:create_spec(Opts) of
		{ok, Spec} ->
			Timeout = maps:get(timeout, Opts, ?TIMEOUT),
			post(Pid, Path, Spec, #{force_new=>true, timeout=>Timeout});
		{error, Error} ->
			{error, Error}
	end.


%% @doc Equivalent to rmi(Pid, Image, #{})
-spec rmi(pid(), text()) ->
	{ok, [map()]} | {error, error()}.

rmi(Pid, Image) ->
	rmi(Pid, Image, #{}).


%% @doc Removes an image.
%% It tries to reuse a previous connection.
-spec rmi(pid(), text(), 
	#{
		force => boolean(),
		noprune => boolean()
	}) ->
	{ok, [map()]} | {error, error()}.

rmi(Pid, Image, Opts) ->
	Path1 = list_to_binary([<<"/images/">>, Image]),
	Path2 = make_path(Path1, Opts, [force, noprune]),
	del(Pid, Path2, #{}).


%% @doc Search images on the repository
-spec search(pid(), text()) ->
	{ok, [map()]} | {error, error()}.

search(Pid, Term) ->
	Path = make_path(<<"/images/search">>, #{term=>Term}, [term]),
	get(Pid, Path, #{force_new=>true, timeout=>?TIMEOUT}).


%% @doc Get a tarball containing all images in a repository
%% Get a tarball containing all images and metadata for the repository specified by name.
%% If name is a specific name and tag (e.g. ubuntu:latest), then only that image 
%% (and its parents) are returned. If name is an image ID, similarly only tha image 
%% (and its parents) are returned, but with the exclusion of the 'repositories' file
%%  in the tarball, as there were no image names referenced.
-spec get_image(pid(), text(), text()) ->
	ok | {error, error()}.

get_image(Pid, Name, File) ->
	Path = list_to_binary([<<"/images/">>, Name, <<"/get">>]),
	Redirect = nklib_util:to_list(File),
	case get(Pid, Path, #{redirect=>Redirect, timeout=>?TIMEOUT}) of
		{ok, <<>>} -> ok;
		{error, Error} -> {error, Error}
	end.


%% @doc Get a tarball containing all images
%% Get a tarball containing all images and metadata for one or more repositories.
%% For each value of the names parameter: if it is a specific name and tag 
%% (e.g. ubuntu:latest), then only that image (and its parents) are returned; 
%% if it is an image ID, similarly only that image (and its parents) are returned 
% and there would be no names referenced in the 'repositories' file for this image ID.
-spec get_images(pid(), [text()], text()) ->
	ok | {error, error()}.

get_images(Pid, Names, File) ->
	Names1 = [["names=", http_uri:encode(nklib_util:to_list(N))] || N <- Names],
	Names2 = nklib_util:bjoin(Names1, <<"&">>),
	Path = <<"/images/get?", Names2/binary>>,
	Redirect = nklib_util:to_list(File),
	case get(Pid, Path, #{redirect=>Redirect, timeout=>?TIMEOUT}) of
		{ok, <<>>} -> ok;
		{error, Error} -> {error, Error}
	end.


%% @doc Loads a binary with a TAR image file into docker
-spec load(pid(), iolist()) -> 
	ok | {error, error()}.

load(Pid, TarBin) ->
	PostOpts = #{
		force_new => true, 
		headers => [{<<"content_type">>, <<"application/tar">>}],
		timeout => ?TIMEOUT
	},
	case post(Pid, <<"/images/load">>, TarBin, PostOpts) of
		{ok, _} -> ok;
		{error, Error} -> {error, Error}
	end.



%% ===================================================================
%% Exec Docker Functions
%% ===================================================================

%% @doc Equivalent to exec_create(Pid, Container, Cmds, #{})
-spec exec_create(pid(), text(), [text()]) ->
	{ok, binary()} | {error, error()}.

exec_create(Pid, Container, Cmds) ->
	exec_create(Pid, Container, Cmds, #{}).


%% @doc Sets up an exec instance in a running container
-spec exec_create(pid(), text(), [text()], 
	#{
		stdin => boolean(),
		stdout => boolean(),
		stderr => boolean(),
		tty => boolean()
	}) ->
	{ok, binary()} | {error, error()}.

exec_create(Pid, Container, Cmds, Opts) ->
	Path = list_to_binary([<<"/containers/">>, Container, <<"/exec">>]),
	Spec = #{
		'AttachStdin' => maps:get(stdin, Opts, true),
		'AttachStdout' => maps:get(stdout, Opts, true),
		'AttachStderr' => maps:get(stderr, Opts, true),
		'Tty' => maps:get(tty, Opts, true),
		'Cmd'=> [to_binary(C) || C <- Cmds]
    },
	case post(Pid, Path, Spec, #{force_new=>true}) of
		{ok, #{<<"Id">>:=Id}} -> {ok, Id};
		{error, Error} -> {error, Error}
	end.


%% @doc Equivalent to exec_start(Pid, Id, #{})
-spec exec_start(pid(), text()) ->
	{ok, binary()} | {error, error()}.

exec_start(Pid, Id) ->
	exec_start(Pid, Id, #{}).


%% @doc Starts a previously set up exec instance id. 
%% TODO: Detach does not seem to work...
%% If you the 'async' option, a reference and connection pid will be returned
%% (see events/2).
-spec exec_start(pid(), text(), 
	#{
		detach => boolean(),
		tty => boolean()
	}) ->
	{ok, binary()} | {ok, reference(), pid()} | {error, error()}.

exec_start(Pid, Id, Opts) ->
	Path = list_to_binary([<<"/exec/">>, Id, <<"/start">>]),
	Spec = #{
		'Detach' => maps:get(detach, Opts, false),
		'Tty' => maps:get(tty, Opts, true)
    },
	case Opts of
		#{detach:=true} ->
			post(Pid, Path, Spec, #{force_new=>true});
		_ ->
			Timeout = maps:get(timeout, Opts, 3600000),
			post(Pid, Path, Spec, #{async=>true, timeout=>Timeout})
	end.


%% @doc Return low-level information about the exec command.
%% It tries to reuse a previous connection.
-spec exec_inspect(pid(), text()) ->
	{ok, binary()} | {error, error()}.

exec_inspect(Pid, Id) ->
	Path = list_to_binary([<<"/exec/">>, Id, <<"/json">>]),
	get(Pid, Path, #{}).


%% @doc Resizes the tty session used by the exec command id. 
%% This API is valid only if tty was specified as part of creating 
%% and starting the exec command.
%% It tries to reuse a previous connection.
-spec exec_resize(pid(), text(), integer(), integer()) ->
	ok | {error, error()}.

exec_resize(Pid, Id, W, H) ->
	Path1 = list_to_binary([<<"/exec/">>, Id, <<"/resize">>]),
	Path2 = make_path(Path1, #{h=>H, w=>W}, [h, w]),
	case post(Pid, Path2, #{}) of
		{ok, <<>>} -> ok;
		{error, Error} -> {error, Error}
	end.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec get(pid(), binary(), nkdocker_server:cmd_opts()) ->
	{ok, map()|binary()} | {error, error()}.

get(Pid, Path, Opts) ->
	nkdocker_server:cmd(Pid, <<"GET">>, Path, <<>>, Opts).


%% @private
-spec post(pid(), binary(), nkdocker_server:cmd_opts()) ->
	{ok, map()|binary()} | {error, error()}.

post(Pid, Path, Opts) ->
	post(Pid, Path, <<>>, Opts).


%% @private
-spec post(pid(), binary(), binary()|iolist()|map(), nkdocker_server:cmd_opts()) ->
	{ok, map()|binary()} | {error, error()}.

post(Pid, Path, Body, Opts) ->
	nkdocker_server:cmd(Pid, <<"POST">>, Path, Body, Opts).


%% @private
-spec del(pid(), binary(), nkdocker_server:cmd_opts()) ->
	{ok, map()|binary()} | {error, error()}.

del(Pid, Path, Opts) ->
	nkdocker_server:cmd(Pid, <<"DELETE">>, Path, <<>>, Opts).


%% @private
make_path(Path, Opts, Valid) ->
	OptsList = [{K, V} || {K, V} <- maps:to_list(Opts), lists:member(K, Valid)],
	nkdocker_opts:make_path(Path, OptsList).


%% @private
get_filters(#{filters:=Filters}=Opts) ->
	Filters1 = maps:map(
		fun(_K, V) -> 
			case is_list(V) of
				true -> [to_binary(T) || T <- V]; 
				false -> [to_binary(V)] 
			end
		end, 
	Filters),
	Opts#{filters:=Filters1};
get_filters(Opts) ->
	Opts.


%% @private
add_authconfig(#{username:=User, password:=Pass, email:=Email}=Opts, Res) ->
	Json = 
		jiffy:encode(
			#{
				username => to_binary(User), 
				password => to_binary(Pass), 
				email => to_binary(Email), 
				serveraddress => to_binary(maps:get(serveraddress, Opts, ?HUB))
			}),
	Hds = maps:get(headers, Res, []),
	Res#{headers => Hds ++ [{<<"x-registry-auth">>, base64:encode(Json)}]};

add_authconfig(_, Res) ->
	Res.



