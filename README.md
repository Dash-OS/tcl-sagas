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