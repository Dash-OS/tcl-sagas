```tcl

# Asynchronously execute any number of "requests", gather the results, 
# process as-needed, dispatch to a callback when ready.
saga run {
  # $args is any values provided at the tail of the command when using
  # [saga run].
  set args [lassign $args callback]
  
  # requester is going to be our pooled saga.  This will be called once for 
  # every arg we feed to saga pool.  All of the sagas will run simultaneously
  # and asynchronously.  When a value is available 
  set requester {
    try {
      set url    [dict get $args url]
      set token  [::http::geturl $url -timeout 10000 -command [saga await] ]
      set status [::http::status $token]
      set data   [::http::data   $token]
      ::http::cleanup $token
      saga resolve [dict create status $status data $data]
    } trap cancel { reason } {
      # Make sure we cleanup if we get cancelled! 
      # If this worker does get cancelled it simply cleans up and quietly 
      # finishes its evaluation.
      ::http::cleanup $token
      saga cancel $reason
    } on error { result options } {
      # Or if we find an error
      ::http::cleanup $token
      # In the case of an error we will immediately cancel the entire 
      # pool. Dispatching [saga error] allows us to conduct a top-down 
      # cancellation (rather than the top-up resolution of a cancel command).
      saga error $result
    }
  }
  
  # [saga pool] provides us with a convenient way to simultaneously trigger
  # multiple asynchronous operations and wait for all of the commands before 
  # processing the results.  
  #
  # In this case two forked executions of $requester would be created and 
  # our evaluation will be suspended asynchronously until every request
  # has either timed out, resolved, or had an error. 
  #
  # Responses is a list of responses in the same order that each set of 
  # arguments was provided in the original command.
  try {
    set responses [ saga pool $requester {*}$args ]
  } trap cancel { reason } {
    #
    # Handle external cancellation of the pool here.
    #
    saga cancel [saga self]
  } on error {result options} {
    # If an error occurs within any worker, none of the workers
    # values will be returned (due to us dispatching [saga error])
    #
    # ...do something with the error here
    #
  }
  
  # If we have responses available, call our callback with the results.
  if { ! [string equal $responses {}] } {
    {*}$callback $responses
  }
  
  
} $callback $request1 $request2 ; # ... ?...requests?

```

```tcl
# A simple saga which will simply execute $script every $delay until either
# cancelled or an error occurs. 
saga run Every {
  try {
    set args [ lassign $args delay ]
    while 1 {
      saga wait $delay
      foreach script $args {
        uplevel #0 [list {*}$script]
      }
    }
  } trap cancel { reason } {
    puts "Every Cancelled: $reason"
  } on error { result options } {
    puts "Every Evaluation Error: $result"
  }
} 10000 { puts foo } { puts bar }
```


```tcl
# An example of the "every" command provided as a saga.  While the above 
# gives us a single every process, the below provides a new command [every]
# which can be called to builds the sagas and manage them for us.
#
# We are doing a couple of things here.
#
# 1. We use [saga create] instead of [saga run].  While saga run would work,
#    create will run the saga then assign an alias to the path so that we can
#    run it by calilng the alias (rather than the return value).z
#
# 2. We wait within a loop for any requests to generate an every command.  This
#    is done by calling [saga await] which suspends its execution until it is
#    awoken again with the results.
#    
#    In many ways it works very similar to [proc] except we now have closures, 
#    asynchronous capabilities, and we can pause/resume the execution of the
#    saga at any point. 
saga create ::every {
  set uid 0
  set ids [dict create]
  while 1 {
    set scripts [ lassign [saga await] delay ]
    if { [string is entier -strict $delay] } {
      set everyID ev#[incr uid]
      set sagaID [ saga run Every $everyID $delay {*}$scripts ]
      dict set ids $everyID $sagaID
    }
  }
}

proc Every {id delay args} {
  try {
    while 1 {
      saga wait $delay
      foreach script $args {
        uplevel #0 [list {*}$script]
      }
    }
  } trap cancel { reason } {
    puts "Every Cancelled: $reason"
  } on error { result options } {
    puts "Every Evaluation Error: $result"
  }
}

every 5000 { puts foo } { puts bar }
every 10000 [list myCommand $foo]
```

```tcl
# Start 4 forked workers that make requests, generate worked processors, and await
# the results.
saga run {
  saga fork {
    # saga 1
  } {
    # saga 2
  } {
    # saga 3
  } {
    # saga 4
  }
  while 1 {
    # Await "REQUEST" to be dispatched by our pool of sagas, process 
    # the results asynchronously and await more requests, dispatch 
    # response (or any other kind of follow0up needed)
    set request [saga take "REQUEST"]
    # Generate a forked saga which will asynchronously process the request
    # and handle it as-needed.
    saga fork {
      saga upvar request
      set response {} ; # ... do something with $request
      saga dispatch "RESPONSE" $response
    }
  }
}
```

## Saga Effects

Below is the implementation of the saga effects. 

```tcl
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
class@ create effects {
  
  variable S
  variable AFTER_IDS
  variable TASKS
  
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
  method cancel { uid child {coro {}} {reason {}} } {
    if { $coro eq {} } { set coro $child }
    if { [info commands $coro] ne {} } {
      if { $reason eq {} } { set reason "Cancelled by: $child via $uid" }
      tailcall inject $child [list throw cancel $reason]
    }
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
    set afterID [ after $delay [list [namespace current]::my$S After $uid $child $body] ]
    dict set AFTER_IDS $uid $afterID
    return $afterID
  }

  method After { uid child body } {
    dict unset AFTER_IDS $uid
    my$S Run [namespace tail $child] $body
  }
  
  # saga wait $delay
  # 
  # Since we need to be friendly to our neighbors, when we want to pause our 
  # execution we use [saga wait $delay] to do so.  This will pause the execution
  # of the given saga for the given time while continuing to allow evaluations,
  # injections, and executions by children.
  method wait { uid child delay args } {
    dict set AFTER_IDS $uid [ after $delay [list [namespace current]::my$S Resolve $uid $child {*}$args] ]
    return _
  }
  
  method Resolve { uid child args } {
    dict unset AFTER_IDS $uid
    $child
  }
  
  method await { uid child } {
    
  }
  
  # saga take MSG ?...MSGS?
  #
  # saga take allows you to pause the current execution and await a dispatched
  # message from other sagas within the context.  The result of the take will 
  # be the args which were dispatched with the message.  
  #
  # Note that should your saga be awaiting messages and there is no longer a 
  # possibility that your message will be received, the saga will be cancelled
  # automatically.
  method take { uid child args } {
    
  }
  
  method upvar { uid child var {as {}} } {
    
  }
  
  # saga dispatch $msg ?...args?
  # 
  # saga dispatch transmits a message that will pass to any listening
  # sagas within the context.  This is how we can faciliate communication
  # between different asynchronous contexts in an efficient manner.
  #
  # When called, the response to the dispatch is a number indicating how
  # many listeners received the dispatch.
  method dispatch { uid child msg args } {
    
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
    tailcall inject $child [list [namespace current]::nsvar@$S [self] {*}$args]
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
  method uplevel { uid child n body } {
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
    inject $target [list try [subst -nocommands {yield [try {$script}]}]]
    return [$target]
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
  method complete { uid child args } {
    my$S Set_Task $child info done 1
    inject $child { saga continue }
    return _
  }
  
  # saga continue
  #
  # saga continue is a simple mechanism for delaying the removal of a saga until we 
  # are ready for its completion (at which point we will either cancel or destroy it).
  # 
  # This is almost entirely for internal use. Calling this from within your saga will
  # cause the saga to pause indefinitely.
  method continue { uid child args } {
    inject $child { saga continue }
    return _
  }
  
}




```