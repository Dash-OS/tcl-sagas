class@ create ::saga::runner {
  
  # REGISTRY is applied as a namepace variable to our classes namespace
  # so that it can be accessed by any instances of our class.
  ::variable REGISTRY {}
  
  # Our Sagas name
  variable NAME
  
  # Our $SYMBOL value which is used to uniquely identify sagas from other
  # values such as standard coroutines.  This is also used to hide the
  # class commands from the saga's context.
  variable S
  
  # Our static register class allows instances to register data to the shared
  # class state to aid in coordination of each instance. If we try to run a
  # saga which has the same name another saga which is currently running we 
  # will cancel the previous before starting the new.
  static register {name path} {
    variable REGISTRY
    if { [dict exists $REGISTRY $name] } {
      [dict get $REGISTRY $name path] cancel
    }
    dict set REGISTRY $name path $path
    return
  }
  
  static complete { name } {
    variable REGISTRY 
    dict unset REGISTRY $name
  }
  
  # Dispatch to the given saga.  Since this command is a class proc, we need to 
  # use it to find the root of our saga that we want to route our dispatch into.
  static dispatch {name msg args} {
    variable REGISTRY
    if { [dict exists $REGISTRY $name path] } {
      [dict get $REGISTRY $name path]::root external_dispatch $msg {*}$args
    }
  }
  
  # This can be used to dispatch a message to all registered sagas without first
  # knowing their name / id.
  static broadcast {msg args} {
    variable REGISTRY
    dict for { name params } $REGISTRY {
      if { [dict exists $params path] } {
        catch { [dict get $params path]::root external_dispatch $msg {*}$args }
      }
    }
  }

  constructor {name body args} {
    # Capture $SAGA_SYMBOL from our parents namespace.
    nsvar SAGA_SYMBOL
    set S    _${SAGA_SYMBOL}
    set NAME $name
    # Call our static proc to register this instance with the classes registry.
    static register $NAME [self]
    # asynchronously start the saga
    my start $body {*}$args
  }
  
  destructor {
    namespace delete [namespace current]
  }
  
  # Create our <SagaContext> which will coordinate our sagas
  method start {body args} {
    ::saga::context create root $S [self] [namespace parent [namespace parent]] $body {*}$args
  }
  
  # When our context calls "complete" we will remove ourselves and all children
  # from the stack
  method complete {} {
    static complete $NAME
    [self] destroy
  }
  
  
}

class@ create ::saga::context {
  
  # mixin our <SagaEffects> to be used by our <SagaCoroutine>'s.
  mixin ::saga::effects
  
  # this is our $SAGA_SYMBOL value which is used for identifications of 
  # sagas.
  variable S
  # this is used to identify each task incrementally.  Each task simply increases
  # the value by 1.
  variable I
  # this is used to provide a unique id to every effect we dispatch.
  variable U
  # our runner / container
  variable R
  # a [dict] which will hold any scheduled [after] executions so that we can
  # cancel them in the event we are cancelled or destroyed.
  variable AFTER_IDS
  # a [dict] which holds information on every forked task.  This is how we identify
  # and handle cancellation and cleanup. 
  variable TASKS
  variable POOL
  
  
  constructor {s r ns body args} {
  
    set S $s
    set I 0
    set U 0
    set R $r
    
    # create an alias [saga] which is used to handle the resolution of <SagaEffects>.
    interp alias {} [namespace current]::saga {} [namespace current]::my$S effect
    # Command protection to stop the user from accidentally breaking the sagas by
    # calling generally malicious commands to the saga context.
    interp alias {} [namespace current]::info {} [namespace current]::my$S info
    interp alias {} [namespace current]::yield {} [namespace current]::my$S yield
    interp alias {} [namespace current]::yieldto {} [namespace current]::my$S yield
    
    # We want to hide the [class@] (meta class) and [::oo::class] procedures from
    # the <SagaCoroutines>.  We simply rename them by appending our $SAGA_SYMBOL
    # value (_@@S) to each command. 
    rename my my$S
    rename nsvar nsvar$S
    rename static static$S
    rename prop prop$S
    rename nsvar@ nsvar@$S
    # Build an embedded namespace which will house all of our tasks.  Because of this
    # we can simply remove the instance and all children tasks will be cancelled
    # automatically.
    namespace eval c {}
    
    # start our <CoordinatorCoroutine> 
    coroutine coordinator$S my$S saga
    
    # build our first root task and execute our sagas content within the <SagaContext>
    my$S Run {} $body {*}$args
    
  }
  
  destructor {
    if { $TASKS ne {} } { my$S cancel_all }
    dict for {k v} $AFTER_IDS { after cancel $v }
    namespace delete c {}
    rename coordinator$S {}
  }
  
  method yield args {
    throw error "Sagas should never call yield or yieldto.  Use the appropriate \[saga\] commands instead.  You likely should be calling \[saga await\], or \[saga wait\]"
  }
  
  # protection against the user calling [info coroutine].  This insures that we are calling
  # our parent coroutine when this is requested so that we return to the parent context.  Decided 
  # to do it this way rather than throw an error. 
  method info { what args } {
    if { $what eq {coroutine} } {
      tailcall saga self
    } elseif { $what eq {_coroutine} } {
      set what {coroutine}
    }
    tailcall ::info $what {*}$args
  }
  
  method uid {} { return e_[incr U] }
  
  # This is the method that is actually being called by our <SagaCoroutine>'s when they
  # call [saga].  This is handeled by the [interp alias] in the <constructor>.
  method effect args {
    tailcall ::yieldto [namespace current]::coordinator$S [list [info _coroutine] [my$S uid] {*}$args]
  }
  
  # This is the entry point for our <CoordinatorCoroutine>.  This is used to handle the
  # execution of all of our tasks and it works by simply receiving an <effect>, passing 
  # it to the effects, and yielding to the caller with the result (or pausing the caller if
  # needed)
  method saga args {
    set response {}
    lassign [ ::yield ] child path
    while 1 {
      try {
        if { ! [string equal $response $S ] } {
          set args [ lassign {*}[::yieldto $child $response] child uid cmd ]
        } else {
          set args [ lassign [::yield] child uid cmd ]
        }
        if { $cmd ne {} } {
          set response [ my$S $cmd $uid $child {*}$args ]
        } else { set response {} }
      } trap cancel { reason } {
        # This should never really happen, redundancy trap
        break
      } trap {TCL COROUTINE YIELDTO_IN_DELETED} {r} {
        # This could only happen when our saga fails due to initial errors, etc.
        break
      } on error {result options} {
        # TODO: How to handle an error here?
        puts "Error Received: $result"
        puts $options
      }
    }
    # We should never reach here unless we died or were cancelled.
    catch { [self] destroy }
  }
  
  method cmdlist args { join $args \; }
  
  # TODO: This can definitely be cleaned up.
  method Run { path body {context {}} args } {
  
    if { $path ne {} } { 
      set child [string cat [string map [list $S {}] $path] _ [incr I]] 
    } else { set child [incr I] }
    
    set c [ coroutine c::${child}${S} ::apply [list \
      {_child _ctx args} [my$S cmdlist \
        { if { ${_ctx} ne {} } { dict with _ctx {} } } \
        { unset _ctx } \
        {::yield [info _coroutine]} \
        [list try $body \
          trap cancel { reason } { saga cancelled } \
          on error {result options} { puts "SAGA ERROR: $result" } \
        ] \
        {saga complete}
      ] [namespace current]
    ] $child $context $args ]
    dict set TASKS {*}[string map { _ { c }} $child] info [dict create \
      coro   [namespace tail $c] \
      path   $child \
      parent $path
    ]
    # Tell our coordinator to start the created <SagaContext>
    after 0 [list [namespace current]::coordinator$S [list $c $child]]
    return [namespace tail $c]
  }
  
  method ResolveChild { child } {
    if { [string match "::*" $child] } { return $child }
    return [namespace current]::c::$child
  }
  
  # Path Utiity methods to help resolve asynchronous paths
  method Path { child } {
    return [lrange [split [namespace tail $child] _] 0 end-1]
  }
  
  method Path_Level { start n } {
    tailcall string cat \
      [namespace qualifiers $start] :: \
      [join [list 1 {*}[lrange [my$S Path $start] 1 end-$n] ] _] \
      $S
  }
  
  method Task_Path { child } {
    return [join [my$S Path $child] { c }]
  }
  
  method Set_Task { child args } {
    dict set TASKS {*}[my$S Task_Path $child] {*}$args
  }
  
  method Get_Task { child } {
    return [dict get $TASKS {*}[my$S Task_Path $child]]
  }
  
  method For_Children { coro vars script } {
    set task [my$S Get_Task $coro]
    if { [dict exists $task c] } {
      uplevel 1 [list dict for $vars [dict get $task c] $script]
    } else { uplevel 1 [list set [lindex $vars 0] {}] }
  }
  
  method Has_Children { coro } {
    return [dict exists [my$S Get_Task $coro] c]
  }
  
  method Remove_Task { child } {
    set path [my$S Task_Path $child]
    dict unset TASKS {*}$path
    my$S Check_Parent_Task $child $path
  }
  
  method Check_Parent_Task { child {path {}} } {
    if { $path eq {} } { set path [my$S Task_Path $child] }
    set parent [lrange $path 0 end-1]
    if { $parent ne {} && [dict exists $TASKS {*}$parent] && [dict get $TASKS {*}$parent] eq {} } {
      set parent_root [lrange $parent 0 end-1]
      if { ! [dict exists $TASKS {*}$parent_root info] } {
        dict unset TASKS {*}$parent_root
        tailcall my$S Check_Parent_Task $child $parent_root
      } elseif { [dict exists $TASKS {*}$parent_root info done] } {
        dict unset TASKS {*}[lrange $parent 0 end-1]
        tailcall my$S Check_Parent_Task $child $parent_root
      }
    }
    if { $TASKS eq {} } { my$S Saga_Complete }
  }
  
  method Saga_Complete {} {
    $R complete
  }
  
  # Attempt to capture the pool id of a child
  method GetPoolID { child } {
    set tail [split [string map [list $S {}] [namespace tail $child]] _]
    set e    [lsearch -glob $tail pool*]
    set pool_id [lindex $tail $e]
    lassign [split $pool_id -] pool_id pool_n
    set pool_id [join [list {*}[lrange $tail 0 [expr { $e - 1 }]] $pool_id] _]
    puts $pool_id
    puts $pool_n
    return [list $pool_id $pool_n]
  }
  
  method BuildPoolID { child } {
    return [string cat [string map [list $S {}] $child] _ pool[incr I]] 
  }
  
  method PoolAggID { child } {
    set tail [split [string map [list $S {}] [namespace tail $child]] _]
    set e [lsearch $tail pool]
    set agg_id [join [lrange $tail 0 [expr { $e + 1 }]] _]
    append agg_id _ agg
    return $agg_id
  }
  
}
