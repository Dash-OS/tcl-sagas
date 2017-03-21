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

## Saga Globals

Saga provides a few commands which can be called globally (from outside a saga's context) 
to work with and manipulate sagas.

 - `saga run`
 - `saga dispatch`
 - `saga take`
 - `saga broadcast`
 - `saga cancel`
 - `saga exists`

## Saga Effects

As a starting point for the documentation, [saga] defines the following "effects" which 
are available to any [saga] context.

 - `saga fork`
 - `saga spawn`
 - `saga call`
 - `saga sleep`
 - `saga await`
 - `saga after`
 - `saga self`
 - `saga pool`
 - `saga cancel`
 - `saga resolve`
 - `saga dispatch`
 - `saga take`
 - `saga race`
 - `saga vwait`
 - `saga variable`
 - `saga upvar`
 - `saga uplevel`
 - `saga level`
 - `saga parent`
 - `saga eval`

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

puts "[clock microseconds] | Running the Saga!"

saga run HTTP {
  
  puts "[clock microseconds] | Saga Starts Evaluation"
  
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
      puts "[clock microseconds] | $pool_id-$pool_n | Request Handler Starts"
      if { ! [info exists url] } {
        saga resolve error "No URL Provided"
      } else {
        # We are able to handle the HTTP Request similarly to how we would if
        # we were doing so synchronously.
        set token [::http::geturl $url -command [saga self] -timeout $timeout]
        # Pause and wait for the http request to complete (or timeout)
        saga await
        puts "[clock microseconds] | $pool_id-$pool_n | Request Handler - Response Received"
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
  puts "------------------------------------------------"
  puts "[clock microseconds] | Results Callback Received"
  puts "------------------------------------------------"
  puts "Results: $results"
  puts "Options: $options"
  puts "------------------------------------------------"
}

# With [saga pool], each element should be a dict where the keys will become
# variables within the forked context.  For each dict that is received, a 
# forked saga will be created.  Our result handler will be called once 
# all requests have completed and are available.  
#
# We can setup multiple forks as we are continually servicing the [saga take] 
# in a loop until we are explicitly cancelled.

puts "[clock microseconds] | Starting Request Dispatches"

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

```

So now lets look at an example output.  In this example it would appear we had 
some network latency with the first request.  This ends up showing what pool is 
doing for us since it waits for the results of the cluster before reporting to 
the callback.

We could, of course, decide we would rather receive responses as quickly as
possible in which case we simply would call the callback from each pool script and
not define a ResultHandler at all.  In this case we do not aggregate the results 
at all.

> Timestamps are seen in `[clock microseconds]`.

```tcl
###### Example Output
#
# 1490053630766088 | Running the Saga!
# 1490053630767397 | Starting Request Dispatches
# 1490053630767902 | Saga Starts Evaluation
# 1490053630770704 | 1_2_pool4-1 | Request Handler Starts
# 1490053630775409 | 1_2_pool4-2 | Request Handler Starts
# 1490053630777093 | 1_3_pool7-1 | Request Handler Starts
# 1490053630778764 | 1_3_pool7-2 | Request Handler Starts
# 1490053630834844 | 1_2_pool4-1 | Request Handler - Response Received
# 1490053630844328 | 1_3_pool7-1 | Request Handler - Response Received
# 1490053630856961 | 1_3_pool7-2 | Request Handler - Response Received
# ------------------------------------------------
# 1490053630858315 | Results Callback Received
# ------------------------------------------------
# Results: 1 {result {ok 301 {Data Would Be Here}} args {url http://www.yahoo.com}} 
#          2 {result {ok 200 {Data Would Be Here}} args {url http://www.bing.com}}
# Options: timeout 10000 callback results
# ------------------------------------------------
# 1490053630860929 | 1_2_pool4-2 | Request Handler - Response Received
# ------------------------------------------------
# 1490053630862089 | Results Callback Received
# ------------------------------------------------
# Results: 1 {result {ok 200 {Data Would Be Here}} args {url http://www.google.com}} 
#          2 {result {ok 200 {Data Would Be Here}} args {url http://www.bing.com}}
# Options: timeout 5000 callback results
# ------------------------------------------------
```