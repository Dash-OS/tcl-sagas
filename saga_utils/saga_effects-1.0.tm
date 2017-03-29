# effects provide us with our [saga] api methods which are called from within 
# a sagas context.  any methods here may be called using [saga $cmd {*}$args] 
# from anywhere that our context still exists.  
# 
# One may define new methods here to extend the capabilities of the sagas.
# Every method will be called with the args [list uid child ...args] where
# uid and child are automatically provided and args are the args that were
# sent to the saga command.
#
# effects are always called from within the sagas coordinator coroutine and the
# saga which requested the effect is awaiting a response before it continues its 
# evaluation.
#
# Note that since we are utilizing coroutines, they are actually awaiting a response
# in an asynchronous fashion.  We do not [yield] or [yieldto] directly in most cases.
# Instead we simply return the desired result (if any) like any other command.  
#
# type <SagaEffect>
#   context:   <CoordinatorCoroutine>
#   namespace: <CoordinatorNS>
#   arguments:
#
#     uid   - $uid is just a unique id for each request.  This is helpful in identifying
#             the state of our sagas. For example, this is used to store the [after] ID's
#             and coroutine paths when we await things asynchronously so that we can continue
#             or cancel execution as-needed.
#
#     child - $child is the saga which is requesting the effect (its coroutine path).  
#             While you could directly [yieldto $child], in most cases you should not
#             do this, instead allowing the higher-order coordination to handle the 
#             overall execution and coordination.
#             
#             This may not always be the case, however.  For example, when the [saga wait] 
#             command is called, we want the saga which called the effect to asynchronously
#             wait for us to re-enable its execution. 
#
#             When we do not want to re-execute the calling saga, we simply return $S which
#             is not alowed to be passed to the sagas anyway.  When this is done, instead of
#             conducting a [yieldto $child] we instead simply [yield] and await for the next
#             effect to be requested.
#
#     args -  Any args that are provided with the [saga $effect] command will be passed to 
#             the effect.
#
#
class@ create ::saga::effects {
  
  variable S
  variable AFTER_IDS
  variable TASKS
  variable POOL
  
  # saga fork $script
  #
  # saga fork allows us to "fork" our execution into a new child saga which runs
  # in parallel to its siblings.  A forked saga will be pushed into the event loop
  # and will execute as soon as the event loop is serviced.  This means that calling
  # multiple [saga forks] in a row will queue and execute them upon the never entry
  # in a FIFO fashion.
  #
  # The saga itself is created synchronously.  Once the saga has been initialized it 
  # will then enter the loop to await execution.
  #
  # If any ancestor (not sibling) of the forked saga is cancelled, the forked task and
  # all of its children will also be cancelled (they will be cancelled before their ancestors).
  # This is true regardless of which part of our tree was cancelled, we always bubble down from 
  # the top during cancellation. 
  method fork { uid child args } {
    set child [expr { [string match ::* $child] ? [namespace tail $child] : $child }]
    my$S Run $child [lindex $args end] {*}[lrange $args 0 end-1]
  }
  
  # saga spawn name $script {*}$args
  #
  # spawn allows us to create an entirely new root saga which will not be affected
  # by cancellations and will begin its own context.  A spawned saga has very little
  # connection to its creator and behaves as-if it were called from the global level.
  method spawn { uid child } {
    
  }
  
  # saga call saga ?...sagas?
  #
  # [saga call] allows us to synchronously execute one or more sagas in parallel,
  # awaiting the response of all of the sagas before continuing execution of 
  # the parent saga.
  #
  # calls may be any command and they may resolve their result at anytime so-long 
  # as the saga remains within the context of itself (no after 0 or coroutines inbetween).
  # 
  # A command is resolved when [saga resolve $result ?...results?] is called or when
  # a value is implicitly returned.
  method call { uid child args } {
    
  }
  
  method Call { uid child cmd } {
    
  }
  
  # saga race saga ?...sagas?
  #
  # a race is similar to a [saga call] except that we execute each provided 
  # saga (or command) simultaneously and will return only the first saga 
  # which completes its evaluation.
  #
  # Once a saga completes its evaluation, we will cancel all other calls
  # immediately. 
  method race { uid child args} {
    
  }
  
  # Force cancel all children / tasks (as if called from root).
  method cancel_all {} { my$S [my$S uid] 1_$S 1_$S }
  
  # saga cancel ?saga? ?reason?
  #
  # Dispatch a cancellation to the saga indicated.  A cancellation will cause
  # a top-down cancellation of a saga.  For example, if a saga has 10 forked
  # children at various nested levels, they will be cancelled in a LIFO fashion
  # until the cancellation has reached the saga indicated. 
  #
  # Sagas may chose to trap cancellation during their execution so that they 
  # may appropriately cleanup in any way they desire before the cancellation
  # continues to it's ancestors.  
  #
  # Trapping a cancellation will not stop the cancellation itself.  Once a cancelled
  # saga returns to the coordinator it will be removed and cancellation will continue.
  method cancel { uid child {coro self} {reason {}} } {
    if { $coro eq {} } { return }
    if { $coro eq "self" } { set coro $child } elseif { [dict exists $AFTER_IDS $coro] } {
      after cancel [dict get $AFTER_IDS $coro]
      dict unset AFTER_IDS $coro
    } else {
      set coro [my$S ResolveChild $coro]
      if { [info commands $coro] ne {} } {
        if { $reason eq {} } { set reason "Cancelled by: [namespace tail $child] via $uid" }
        set signal [list throw cancel $reason]
        my$S cancel_children $uid $coro $signal
        my$S cancel_eval $uid $coro $signal
      }
    }
    return
  }
  
  # This will iterate through the children of the given child and cancel each of them
  # from the top down.  It iterates and continually calls cancel on their children until
  # we reach the top then work our way down.
  method cancel_children { uid child signal } {
    my$S For_Children $child { id params } {
      if { [dict exists $params c] } { 
        my$S cancel_children $uid [dict get $params info coro] $signal 
      }
      if { [dict exists $params info killed] } { continue }
      if { ! [dict exists $params info done] } {
        set coro [my$S ResolveChild [dict get $params info coro]]
        my$S cancel_eval $uid $coro $signal
      }
    }
  }
  
  method cancel_eval { uid coro signal } {
    coro inject $coro $signal
    set i 10
    # Give the saga time to handle cancellation by providing a limited subset
    # of effects
    set complete 0
    while { $i > 0 && ! $complete } {
      set args [ lassign {*}[ ::yieldto $coro ] c u effect ]
      switch -glob -- $effect {
        complete - cancelled { 
          set complete 1
          break
        }
        eva* - pa* - se* - di* - var* - up* { my$S $effect $uid $coro {*}$args }
        default {
          # Tried to do an illegal effect, force kill now
          set complete 1
          break
        }
      }
      incr i -1
    }
    my$S complete $uid $coro 1
  }
  
  # saga after $delay then $script
  #
  # Similar to the standard [after $delay $script] idiom, this allows you to 
  # schedule a saga to occur in the future.  This works the same way as [saga fork]
  # in the sense that you end up with an indepdendent frame of execution, its evaluation
  # is simply delayed for the given time indicated by $delay.
  method after { uid child delay args } {
    set args [lassign $args then body]
    if { ! [string equal $then then] } { set body $then }
    set afterID [ after [my$S parse_time $delay] [list [namespace current]::my$S After $uid $child $body] ]
    dict set AFTER_IDS $uid $afterID
    return $uid
  }

  method After { uid child body } {
    dict unset AFTER_IDS $uid
    my$S Run [namespace tail $child] $body
  }
  
  # A helper function to allow parsing time in various ways
  #
  # parse_time 5000 -> 5000
  # parse_time 5 seconds -> 5000
  # parse_time 1 minute 10 seconds -> 70000
  method parse_time args {
    if {[llength $args] == 1} {
      if { [string is entier -strict $args] } { return $args }
      set args [lindex $args 0]
    }
    return [expr { [clock add 0 {*}$args] * 1000 }]
  }
  
  # saga wait $delay
  # 
  # Since we need to be friendly to our neighbors, when we want to pause our 
  # execution we use [saga wait $delay] to do so.  This will pause the execution
  # of the given saga for the given time while continuing to allow evaluations,
  # injections, and executions by children.
  method wait { uid child args } {
    dict set AFTER_IDS $uid [ after [my$S parse_time {*}$args] [list [namespace current]::my$S Resolve $uid $child] ]
    return $S
  }
  # saga sleep $delay
  #
  # this may be a better term than [saga wait] - adding it as an alias for now
  method sleep { uid child args } { tailcall my$S wait $uid $child {*}$args }
  
  method Resolve { uid child args } {
    dict unset AFTER_IDS $uid
    $child
  }
  
  # saga await
  #
  # Pauses execution, expecting some inside source to awaken it such as an event.
  method await { uid child } { 
    return $S
  }
  
  # saga take MSG
  #
  # saga take allows you to pause the current execution and await a dispatched
  # message from other sagas within the context.  The result of the take will 
  # be the args which were dispatched with the message.  
  #
  # Note that should your saga be awaiting messages and there is no longer a 
  # possibility that your message will be received, the saga will be cancelled
  # automatically.
  #
  # In addition to the return value, a take may define a fork that should occur
  # when the message is received.  The fork resolves with the message as a varname
  # which holds the values dispatched.  
  #
  method take { uid child msg args } {
    nsvar@$S [self] DISPATCH${S}
    if { ! [info exists DISPATCH${S}(${msg})] } { set DISPATCH${S}(${msg}) {} }
    lappend DISPATCH${S}(${msg}_listeners) $child
    trace add variable DISPATCH${S}(${msg}) write [list [namespace current]::my$S take_resolve $uid $child $msg $args]
    return $S
  }
  
  method take_resolve { uid child msg fork args } {
    nsvar@$S [self] DISPATCH${S} 
    trace remove variable DISPATCH${S}(${msg}) write [list [namespace current]::my$S take_resolve $uid $child $msg $fork]
    set value [set DISPATCH${S}(${msg})]
    if { $fork ne {} } {
      if { [llength $fork] == 1 } {
        my$S fork $uid $child [dict create DISPATCHER [set DISPATCH${S}(${msg}_sender)] $msg $value] {*}$fork
      } else {
        set fork [lassign $fork context]
        my$S fork $uid $child [dict merge \
          $context [dict create DISPATCHER [set DISPATCH${S}(${msg}_sender)] $msg $value]
        ] [set DISPATCH${S}(${msg}_sender)] {*}$fork 
      }
    }
    if { [ set DISPATCH${S}(${msg}_listeners) [lsearch -all -inline -not -exact [set DISPATCH${S}(${msg}_listeners)] $child] ] eq {} } {
      my$S take_cleanup $uid $child $msg $value
    }
    $child {*}$value
  }
  
  method take_cleanup { uid child msg value } {
    nsvar@$S [self] DISPATCH${S}
    unset DISPATCH${S}(${msg})
    unset DISPATCH${S}(${msg}_listeners)
    unset DISPATCH${S}(${msg}_sender)
  }
  
  method upvar { uid child var {as {}} } {
    set value [my$S eval $uid $child [my$S Path_Level $child 1] [my$S cmdlist \
      [list set $var]
    ]]
    if { $as eq {} } { set as $var }
    tailcall coro inject $child [list set $as $value]
  }
  
  # creates $n forked workers which run the body. Unless we were to implement
  # some sort of [Thread] compatiblity where workers could run in threads, I am 
  # not sure how useful this would be.  However, in that case it could provide 
  # 
  method pool { uid child pool_args pool_context args } {
    if { ! [info exists POOL] } { set POOL [dict create] }
    set pool_id [my$S BuildPoolID $child]
    set n    [ llength $pool_args ]
    set args [ lassign $args pool_body aggregator]
    dict set POOL [namespace tail $pool_id] info n $n
    if { $aggregator ne {} } {
      dict set POOL [namespace tail $pool_id] info [dict create \
        ag   $aggregator \
        n    $n \
        pa   $pool_args \
        pc   $pool_context
      ]
    }
    set i 1
    while { $i <= $n } {
      my$S fork $uid ${pool_id}-$i [dict merge \
        $pool_context \
        [lindex $pool_args [expr { $i - 1 }]] \
        [dict create pool_id [namespace tail $pool_id] pool_n $i]
      ] {*}$args $pool_body
      incr i
    }
  }
  
  method pool_check { uid child pool_id args } {
    if { [dict exists $POOL $pool_id info n] && [dict exists $POOL $pool_id results] } {
      set n       [dict get $POOL $pool_id info n]
      set results [dict get $POOL $pool_id results]
      if { [dict size $results] >= $n } {
        if { [dict exists $POOL $pool_id info ag] } {
          set agg_id    [my$S PoolAggID $child]
          set script    [dict get $POOL $pool_id info ag]
          set pool_args [dict get $POOL $pool_id info pa]
          set options   [dict get $POOL $pool_id info pc]
          dict unset POOL $pool_id
          set i 0
          foreach pool_arg $pool_args {
            incr i 
            dict set results $i args $pool_arg
          }
          my$S fork $uid $agg_id [dict create results $results options $options pool_id $pool_id] $script
        }
      }
    }
  }
  
  method resolve { uid child args } {
    if { ! [info exists POOL] } { set POOL [dict create] }
    lassign [ my$S GetPoolID $child ] pool_id pool_n
    dict set POOL $pool_id results $pool_n result $args
    my$S pool_check $uid $child $pool_id
    return 
  }
  
  # saga dispatch $msg ?...args?
  # 
  # saga dispatch transmits a message that will pass to any listening
  # sagas within the context.  This is how we can faciliate communication
  # between different asynchronous contexts in an efficient manner.
  #
  # When called, the response to the dispatch is a number indicating how
  # many listeners received the dispatch.
  method dispatch { uid child {msg {}} args } {
    dict set AFTER_IDS $uid [after 0 [list [namespace current]::my$S dispatch_resolve $uid $child $msg {*}$args]]
    return $S
  }
  
  method external_dispatch { {msg {}} args } {
    set uid [my$S uid]
    #dict set AFTER_IDS $uid [after 0 [list [namespace current]::my$S dispatch_resolve $uid {} $msg {*}$args]]
    return [my$S dispatch_resolve $uid {} $msg {*}$args]
  }
  
  method dispatch_resolve { uid child msg args } {
    dict unset AFTER_IDS $uid
    nsvar@$S [self] DISPATCH${S}
  
    if { [info exists DISPATCH${S}(${msg})] } {
      set listeners [llength DISPATCH${S}(${msg}_listeners)]
      set DISPATCH${S}(${msg}_sender) $child
      set DISPATCH${S}(${msg}) $args
    } else { set listeners 0 }
    if { $child ne {} } { $child }
    return $listeners
  }
  
  # allows vwaiting against a [saga variable] value
  method vwait { uid child vname args } {
    my$S variable $uid $child $vname
    nsvar@$S [self] $vname
    trace add variable $vname write [list [namespace current]::my$S vwait_resolve $uid $child $vname $args]
    return $S
  }
  
  method vwait_resolve { uid child vname fork args } {
    nsvar@$S [self] $vname
    trace remove variable $vname write [list [namespace current]::my$S vwait_resolve $uid $child $vname $fork]
    if { $fork ne {} } {
      if { [llength $fork] == 1 } {
        my$S fork $uid $child [dict create $vname [set $vname]] {*}$fork
      } else {
        set fork [lassign $fork context]
        my$S fork $uid $child [dict merge \
          $context [dict create $vname [set $vname]] $msg $value]
        ] {*}$fork 
      }
    }
    # we call the child synchronously within the callback so that they can schedule
    # a new vwait if required.  If we don't do this then we would miss sets done in 
    # the meantime which would defeat the purpose here.
    $child
  }
  
  # saga variable MyVar ?value?
  #
  # saga variable provides the ability to share one or multiple variables throughout
  # the execution of your saga.  Any child may use this command to retrieve a variable
  # or define one that all children have access to.
  #
  # This is simply an implementation of [namespace upvar] which uses the shared root
  # namespace to hold its variables. 
  method variable { uid child args } {
    tailcall coro inject $child [list [namespace current]::nsvar@$S [self] {*}$args]
  }
  
  # saga self
  #
  # simply ends up returning the value of [info coroutine]
  method self { uid child } { return $child }
  
  # saga level #
  #
  # Returns the fully qualified path to a parent $n levels up from the
  # current frame of execution.
  method level { uid child {n 0} } {
    return [my$S Path_Level $child $n]
  }
  
  # saga parent
  #
  # synonymous with [saga level 1], returns the path to the current 
  # sagas parent.
  method parent { uid child } { tailcall my$S level $uid $child 1 }
  
  # saga uplevel 1 { ...script }
  #
  # similar to a standard uplevel, saga uplevel will evaluate the script within 
  # its parents context and return the result.  While its probably a better idea 
  # in most cases to utilize options like [saga variable] when this functionality
  # is required, there is likely some interesting benefits that can be had with this
  # command.
  #
  # It is important to understand the difference of [saga uplevel] vs [uplevel].  As
  # our execution is asynchronous as we nest each level deeper, a [saga uplevel] command
  # would potentially be evaluating the given script at any point in its evaluation.
  method uplevel { uid child args } {
    lassign $args n body
    if { $body eq {} } {
      set body $n
      set n 1
    }
    tailcall my$S eval $uid $child [my$S Path_Level $child $n] $body
  }
  
  # saga eval $target $script
  #
  # Evaluate $script within the context of the $target where target is a fully 
  # qualified path to the <SagaContext> object.  We will evaluate the script 
  # and return the result in a similar fashion to [uplevel]. 
  # 
  # Once we yield the response of your $script we continue yielding from the
  # same point so that the saga itself should not be affected.  
  #
  # Note that since the eval does occur within the live context of the <SagaContext>,
  # mutating values within $script could result in bugs which are not easy to understand.
  method eval { uid child target script } { 
    dict unset AFTER_IDS $uid
    tailcall coro eval $target $script
  }
  
  # saga complete
  #
  # When a saga completes it evaluation it will call [saga complete] automatically
  # to indicate it has completed its evaluation.  Once this is done, the saga remains
  # alive until all of its children have also completed their evaluation.  This allows
  # us to provide an asynchronous closure-like environment for the duration of the 
  # nested evaluation of our sagas.
  # 
  # There should really never be any reason to manually call this command.  It is 
  # appended to the body on startup.  However, if at any time one wishes to end 
  # the execution of the saga, they may call this command directly, pausing the
  # execution at the point in-which [saga complete] was called until any/all children
  # have completed as well.
  method complete { uid child {force_kill 0} args } {
    my$S Set_Task $child info done 1
    if { $force_kill } {
      my$S kill $uid $child
    } elseif { [my$S Has_Children $child] } {
      coro inject $child { saga continue }
    } else {
      dict set AFTER_IDS $uid [ \
        after 0 [list [namespace current]::my$S eval $uid $child $child { saga kill }]
      ]
    }
    return $S
  }
  
  # saga continue
  #
  # saga continue is a simple mechanism for delaying the removal of a saga until we 
  # are ready for its completion (at which point we will either cancel or destroy it).
  # 
  # This is almost entirely for internal use. Calling this from within your saga will
  # cause the saga to pause indefinitely.
  method continue { uid child args } {
    coro inject $child { saga continue }
    return $S
  }
  
  # Once a saga as been confirmed completed and it has no children that might require
  # its context in the future the saga will be killed.  This process will remove the 
  # coroutine all together, remove the coroutine from our $TASKS, then check to see 
  # if we can then kill the parent.
  method kill { uid child args } {
    rename $child {}
    my$S Remove_Task $child
  }
  
}



