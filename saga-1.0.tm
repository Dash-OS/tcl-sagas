::tcl::tm::path add [file normalize [file dirname [info script]]]

package require saga_dependencies::mclass
package require saga_dependencies::coro
package require saga_utils::saga_effects
package require saga_utils::saga_runner

namespace eval ::saga {
  variable SAGA_SYMBOL "@@S"
  variable I 0 
}

namespace eval ::saga::sagas {}

proc ::saga::auto_id {} { return saga_[incr [namespace current]::I] }

proc ::saga {cmd args} { 
  if { ! [string match *$::saga::SAGA_SYMBOL [info coroutine]] } {
    {*}::saga::$cmd {*}$args 
  } else {
    tailcall [namespace parent [namespace qualifiers [info coroutine]]] effect $cmd {*}$args
  }
}

proc ::saga::run {args} {
  set args [lassign $args name body]
  set id [::saga::auto_id]
  if { [string equal $name {}] && ! [string equal $body {}] } { 
    set name $id
  } elseif { [string equal $body {}] } { 
    set body $name
    set name $id
  }
  ::saga::runner create ::saga::sagas::$id $name $body {*}$args
  return $name
}

proc ::saga::cancel args {
  
}

# Broadcast to the given saga if it is still alive
proc ::saga::dispatch  {name msg args} { ::saga::runner::dispatch $name $msg {*}$args }
# Dispatch to all running sagas within our application.
proc ::saga::broadcast {msg args} { ::saga::runner::broadcast $msg {*}$args }