-module(els_config).

%% API
-export([ initialize/3
        , get/1
        , set/2
        , start_link/0
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        ]).

%%==============================================================================
%% Includes
%%==============================================================================
-include("erlang_ls.hrl").

%%==============================================================================
%% Macros
%%==============================================================================
-define(DEFAULT_CONFIG_PATH, "erlang_ls.config").
-define( DEFAULT_EXCLUDED_OTP_APPS
       , [ "megaco"
         , "diameter"
         , "snmp"
         , "wx"
         ]
       ).
-define(SERVER, ?MODULE).

%% TODO: Refine names to avoid confusion
-type key()   :: app_paths
               | capabilities
               | deps_dirs
               | deps_paths
               | include_dirs
               | include_paths
               | otp_path
               | otp_paths
               | otp_apps_exclude
               | root_uri
               | search_paths.
-type path()  :: file:filename().
-type state() :: #{ app_paths         => [path()]
                  , deps_dirs         => [path()]
                  , deps_paths        => [path()]
                  , include_dirs      => [path()]
                  , include_paths     => [path()]
                  , otp_path          => path()
                  , otp_paths         => [path()]
                  , otp_apps_exclude  => [string()]
                  , root_uri          => uri()
                  , search_paths      => [path()]
                  }.

%%==============================================================================
%% Exported functions
%%==============================================================================

-spec initialize(uri(), map(), map()) -> ok.
initialize(RootUri, Capabilities, InitOptions) ->
  Config = consult_config(filename:join([ els_uri:path(RootUri)
                                        , config_path(InitOptions)
                                        ])),
  OtpPath        = maps:get("otp_path", Config, code:root_dir()),
  DepsDirs       = maps:get("deps_dirs", Config, []),
  IncludeDirs    = maps:get("include_dirs", Config, ["include"]),
  OtpAppsExclude = maps:get( "otp_apps_exclude"
                           , Config
                           , ?DEFAULT_EXCLUDED_OTP_APPS
                           ),
  ExcludePathsSpecs = [[OtpPath, "lib", P ++ "*"]|| P <- OtpAppsExclude],
  ExcludePaths      = resolve_paths(ExcludePathsSpecs, true),
  lager:info("Excluded OTP Applications: ~p", [OtpAppsExclude]),

  %% Passed by the LSP client
  ok = set(root_uri      , RootUri),
  %% Read from the erlang_ls.config file
  ok = set(otp_path      , OtpPath),
  ok = set(deps_dirs     , DepsDirs),
  ok = set(include_dirs  , IncludeDirs),
  %% Calculated from the above
  AppPaths  = app_paths(RootUri, false),
  DepsPaths = deps_paths(RootUri, DepsDirs, false),
  OtpPaths  = otp_paths(OtpPath, false) -- ExcludePaths,
  ok = set(app_paths     , AppPaths),
  ok = set(deps_paths    , DepsPaths),
  ok = set(include_paths , include_paths(RootUri, IncludeDirs, false)),
  ok = set(otp_paths     , OtpPaths),
  ok = set(index_paths   , lists:append([ AppPaths
                                        , deps_paths()
                                        , otp_paths()
                                        ])),
  %% All (including subdirs) paths used to search files with file:path_open/3
  ok = set( search_paths
          , lists:append([ app_paths(RootUri, true)
                         , deps_paths(RootUri, DepsDirs, true)
                         , otp_paths(OtpPath, true)
                         ])
          ),
  %% Init Options
  ok = set(capabilities  , Capabilities),
  ok.

-spec start_link() -> {ok, pid()}.
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, {}, []).

-spec get(key()) -> any().
get(Key) ->
  gen_server:call(?SERVER, {get, Key}).

-spec set(key(), any()) -> ok.
set(Key, Value) ->
  gen_server:call(?SERVER, {set, Key, Value}).

%%==============================================================================
%% gen_server Callback Functions
%%==============================================================================

-spec init({}) -> {ok, state()}.
init({}) ->
  {ok, #{}}.

-spec handle_call(any(), any(), state()) ->
  {reply, any(), state()}.
handle_call({get, Key}, _From, State) ->
  Value = maps:get(Key, State, undefined),
  {reply, Value, State};
handle_call({set, Key, Value}, _From, State0) ->
  State = maps:put(Key, Value, State0),
  {reply, ok, State}.

-spec handle_cast(any(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) -> {noreply, State}.

%%==============================================================================
%% Internal functions
%%==============================================================================

-spec config_path(map()) -> els_uri:path().
config_path(#{<<"erlang">> := #{<<"config_path">> := ConfigPath}}) ->
  ConfigPath;
config_path(_) ->
  ?DEFAULT_CONFIG_PATH.

-spec consult_config(els_uri:path()) -> map().
consult_config(Path) ->
  lager:info("Reading config file. path=~p", [Path]),
  Options = [{map_node_format, map}],
  try yamerl:decode_file(Path, Options) of
      [] -> #{};
      [Config] -> Config
  catch
    Class:Error ->
      lager:warning( "Could not read config file: path=~p class=~p error=~p"
                   , [Path, Class, Error]),
      #{}
  end.

-spec app_paths(uri(), boolean()) -> [string()].
app_paths(RootUri, Recursive) ->
  RootPath = binary_to_list(els_uri:path(RootUri)),
  resolve_paths( [ [RootPath, "src"]
                 , [RootPath, "test"]
                 , [RootPath, "include"]
                 ]
               , Recursive
               ).

-spec include_paths(uri(), string(), boolean()) -> [string()].
include_paths(RootUri, IncludeDirs, Recursive) ->
  RootPath = binary_to_list(els_uri:path(RootUri)),
  Paths = [resolve_paths([[RootPath, Dir]], Recursive) || Dir <- IncludeDirs],
  lists:append(Paths).

-spec deps_paths(uri(), [string()], boolean()) -> [string()].
deps_paths(RootUri, DepsDirs, Recursive) ->
  RootPath = binary_to_list(els_uri:path(RootUri)),
  Paths = [ resolve_paths( [ [RootPath, Dir, "src"]
                           , [RootPath, Dir, "test"]
                           , [RootPath, Dir, "include"]
                           ]
                         , Recursive
                         )
            || Dir <- DepsDirs
          ],
  lists:append(Paths).

-spec otp_paths(string(), boolean()) -> [string()].
otp_paths(OtpPath, Recursive) ->
  resolve_paths( [ [OtpPath, "lib", "*", "src"]
                 , [OtpPath, "lib", "*", "include"]
                 ]
               , Recursive
               ).

-spec resolve_paths([[string()]], boolean()) -> [[string()]].
resolve_paths(PathSpecs, Recursive) ->
  lists:append([resolve_path(PathSpec, Recursive) || PathSpec <- PathSpecs]).

-spec resolve_path([string()], boolean()) -> [string()].
resolve_path(PathSpec, Recursive) ->
  Path  = filename:join(PathSpec),
  Paths = filelib:wildcard(Path),
  case Recursive of
    true  -> lists:append([[P | subdirs(P)] || P <- Paths]);
    false -> Paths
  end.

%% Returns all subdirectories for the provided path
-spec subdirs(string()) -> [string()].
subdirs(Path) ->
  subdirs(Path, []).

-spec subdirs(string(), [string()]) -> [string()].
subdirs(Path, Subdirs) ->
  case file:list_dir(Path) of
    {ok, Files} -> subdirs_(Path, Files, Subdirs);
    {error, _}  -> Subdirs
  end.

-spec subdirs_(string(), [string()], [string()]) -> [string()].
subdirs_(Path, Files, Subdirs) ->
  Fold = fun(F, Acc) ->
             FullPath = filename:join([Path, F]),
             case filelib:is_dir(FullPath) of
               true  -> subdirs(FullPath, [FullPath | Acc]);
               false -> Acc
             end
         end,
  lists:foldl(Fold, Subdirs, Files).

-spec deps_paths() -> [string()].
deps_paths() ->
  case application:get_env(erlang_ls, index_deps) of
    {ok, true} ->
      els_config:get(deps_paths);
    _ ->
      lager:info("Not indexing dependencies due to configuration."),
      []
  end.

-spec otp_paths() -> [string()].
otp_paths() ->
  case application:get_env(erlang_ls, index_otp) of
    {ok, true} ->
      els_config:get(otp_paths);
    _ ->
      lager:info("Not indexing dependencies due to configuration."),
      []
  end.
