# Tcl Sagas 

> **Note:** This is a work in progress!  However, it should be to the point that is is generally useable.  
> We are currently in the process of testing various use-cases to make sure there are not any unforeseen issues 
> with the API. 

## Summary

What Sagas are, or what they look like, has been met with some confusion if you search 
the internet.  At the end of the day, my interpretation of what a Saga looks like is 
really quite simple:

> Saga's provide a means for intelligently handling long-lived (generally) asynchronous 
> transactions.  Specifically making it easy for each step to "clean-up" after itself 
> should a cancellation or undesired result occur later in the transaction.

I'm sure I will need to read, revise, and rewrite that to be more clear at some point, 
but lets take a look at what tcl-saga looks like and hopefully it will become clear 
quickly how this pattern can benefit you. 

## Simple Saga Example

So this example doesn't clearly show what is happening here, but it will have to do 
for now.  Will finish these docs as soon as possible.

```tcl
package require saga

saga run {
  # We are now within a saga.  This will run asynchronously from where it was
  # called and has access to the [saga] effects for handling asynchronous 
  # program flow.
  
  # each "fork" runs asynchronously, but they all share the common "saga" context.
  # This allows us to build some interesting and powerful control flows. 
  saga fork {
    # a simple example is using [saga vwait] to wait for a sibling or decendendent 
    # to set a saga variables value and react upon it.
    while 1 { saga vwait foo {
        # called as a child of our first fork and resolves with the set value.
        puts "saga variable foo set to $foo"
    } }
  }
  
  saga fork {
    # Our second fork will be run independently from the first, but they are still 
    # sharing the context.
    saga variable foo
    set foo "Hi from Fork Two!"
    set foo "Hi Again!"
    # Almost every command in a saga is cooperative to the rest.  When you suspend 
    # in one fork, another will be serviced until we need to wake it up again.
    saga sleep 1 second ; # [saga sleep 1000] works just fine as well.
    set foo "And Again!"
  }
  
  saga fork {
    # Our third fork shows the cooperative nature of our sagas.  All members cooperatively
    # co-exist and coordinate their efforts to reach a common goal.
    saga variable foo
    set foo "Hey from Fork Three!"
  }
  
  # This pattern provides many interesting possiblities. Note that these are asynchronous
  # but they still can do things like:
  set bar "Hello"
  
  saga fork {
    saga upvar bar
    puts "bar is $bar"
    # We can fork as often as needed 
    saga fork {
      saga fork {
        # Our context will remain the same.  
        saga variable foo
        puts "Foo is currently $foo"
        puts "Hello from a Deeply Forked Family Member!"
      }
    }
  }
}

# bar is Hello
# saga variable foo set to Hi from Fork Two!
# saga variable foo set to Hi Again!
# saga variable foo set to Hey from Fork Three!
# Foo is currently Hey from Fork Three!
# Hello from a Deeply Forked Family Member!
# saga variable foo set to And Again!



```

## Saga Pool Example

Below we have a slightly more advanced example where we are utilizing some of sagas 
more powerful features such as [saga uplevel], [saga pool], [saga dispatch], and friends.

With [saga pool], we take a list of dicts which represent the arguments. Each element 
will create an independent fork of the worker.  If a result handler is provided it will 
then be called once all workers in the pool have resolved their results.

[saga] is meant to be a toolkit for handling these kinds of asynchronous data flows without 
the complexity they may normally require. 
 
```tcl
package require saga

saga run HTTP {
  
  # Create our default arguments which can be retrieved from our asynchronous
  # workers as-needed.
  set DefaultOptions [dict create \
    timeout 10000
  ]
  
  # Our RequestHandler is the body that we will fork when the pool is called. 
  # Each element in the list will be simultaneously forked and we will await 
  # the results from all before continuing.
  set RequestHandler {
    try {
      puts "[clock milliseconds] | $pool_id-$pool_n | Request Handler Starts"
      if { ! [info exists url] } {
        saga resolve error "No URL Provided"
      } else {
        # We are able to handle the HTTP Request similarly to how we would if
        # we were doing so synchronously.
        set token [::http::geturl $url -command [saga self] -timeout $timeout]
        # Pause and wait for the http request to complete (or timeout)
        saga await
        puts "[clock milliseconds] | $pool_id-$pool_n | Request Handler - Response Received"
        set status [::http::status $token]
        set ncode  [::http::ncode  $token]
        # For the example we will just capture the status
        saga resolve $status $ncode {Data Would Be Here}
      }
    } trap cancel { reason } {
      saga resolve cancelled $reason
    } on error { result options } {
      saga resolve error $result $options
    } finally {
      if { [info exists token] } {
        ::http::cleanup $token
      }
    }
  }
  
  # Our ResultHandler will receive the aggregated results once all the members of 
  # the given pool have resolved their responses.
  set ResultHandler {
    if { [dict exists $options callback] } {
      after 0 [list [dict get $options callback] $results $options] 
    }
  }
  
  set cancelled 0
  
  # Our while loop will allow us to continuously take REQUEST events then generate
  # the pooled results from there.
  while { ! $cancelled } {
    try {
      saga take REQUEST {
        # Each time a REQUEST is dispatched, we will receive the arguments 
        # in the $REQUEST variable.  In this case we expect two arguments where 
        # the first are options for the pool (which replace the $RequestContext) 
        # and the second is a list of requests to make (each in their own saga).
        lassign $REQUEST options requests
        
        # There are a few ways we can get the variables from our parent context. 
        # Below we are using [saga uplevel] to evaluate and grab them.  We could
        # also use [saga variable] or [saga upvar].
        set request_args [ lassign [saga uplevel {
          list $DefaultOptions $RequestHandler $ResultHandler
        }] default_options ]
        
        # Now we are ready to start our pool.  We merge the request options with the
        # default then feed in the rest of the arguments to start the pool.  
        saga pool $requests [dict merge $default_options $options] {*}$request_args
        
        # We are free to do whatever else, [saga pool] is handled asynchronously
        # so this will occur immediately after the command above.
      }
      
      # After each request is received we want to again take REQUEST so that 
      # we can continuously handle requests.
      
    } trap cancel { reason } {
      # trap cancel allows us to conduct logic should we get cancelled for any
      # reason.  In this case we will simply graciously exit the while loop.
      set cancelled 1
    } on error {result options} {
      puts "Error! $result"
    }
  }

}

# Our results proc will be called by the saga whenever results are made availble.
# We define this through the "options" dict's callback key.
proc results {results options} {
  puts "Request Results Received!"
  puts "Results: $results"
  puts "Options: $options"
}

# With [saga pool], each element should be a dict where the keys will become
# variables within the forked context.  For each dict that is received, a 
# forked saga will be created.  Our result handler will be called once 
# all requests have completed and are available.  
#
# We can setup multiple forks as we are continually servicing the [saga take] 
# in a loop until we are explicitly cancelled.
saga dispatch HTTP REQUEST [dict create \
  timeout 5000 \
  callback results
] [list \
  [dict create url http://www.google.com] \
  [dict create url http://www.bing.com]
]
  
saga dispatch HTTP REQUEST [dict create callback results] [list \
  [dict create url http://www.yahoo.com] \
  [dict create url http://www.bing.com]
]

###### Example Output
#
# 1490052277036 | 1_2_pool4-1 | Request Handler Starts
# 1490052277042 | 1_2_pool4-2 | Request Handler Starts
# 1490052277044 | 1_3_pool7-1 | Request Handler Starts
# 1490052277048 | 1_3_pool7-2 | Request Handler Starts
# 1490052277105 | 1_2_pool4-1 | Request Handler - Response Received
# 1490052277113 | 1_3_pool7-1 | Request Handler - Response Received
# 1490052277128 | 1_2_pool4-2 | Request Handler - Response Received
# 1490052277132 | 1_3_pool7-2 | Request Handler - Response Received
#
# Request Results Received!
# Results: 1 {result {ok 200 {Data Would Be Here}} args {url http://www.google.com}} 
#          2 {result {ok 200 {Data Would Be Here}} args {url http://www.bing.com}}
# Options: timeout 5000 callback results
#
# Request Results Received!
# Results: 1 {result {ok 301 {Data Would Be Here}} args {url http://www.yahoo.com}} 
#          2 {result {ok 200 {Data Would Be Here}} args {url http://www.bing.com}}
# Options: timeout 10000 callback results
#
```