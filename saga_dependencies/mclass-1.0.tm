namespace eval ::class@ {}

::oo::class create ::class@::MasterClass {
	superclass ::oo::class	
	
	method create {name definition args} {
		tailcall my createWithNamespace $name $name $definition {*}$args
	}
	
	self method static args {
		puts self
	}
	
	method static {class name value args} {
	  if { $args ne {} } {
	    lassign $args script
	    tailcall proc ${class}::$name $value $script
	  } else {
	    set ${class}::$name $value
	  }
	}
	
	method prop {class name {data {}}} {
	  if { $data ne {} } { 
	  	variable ${class}::$name $data 
		} elseif { [info exists ${class}::${name}] } {
			return [set ${class}::${name}]	
		}
	 
	}
}


proc ::class@::transferDefineCommands {} {
	foreach cmd [info commands ::oo::define::*] {
	  set tail [namespace tail $cmd]
	  if {$tail eq "self"} { continue }
	  ::oo::define MasterClass method $tail {cls args} {
	  	tailcall ::oo::define $cls [self method] {*}$args
	  }
	}
	rename ::class@::transferDefineCommands {}
}

::class@::transferDefineCommands

::oo::class create ::class@::MetaMixin {
  constructor args {
  	# We use this method so that mixins and superclasses can have their
  	# own static and prop values. 
  	set class [info object class [self]]
  	interp alias {} [namespace current]::static  {} $class static
  	interp alias {} [namespace current]::prop    {} $class prop
  	interp alias {} [namespace current]::nsvar   {} $class nsvar
  	interp alias {} [namespace current]::nsvar@  {} $class nsvar@
  	set qualifiers [namespace qualifiers $class]
  	namespace path [list {*}[namespace path] [namespace current] {*}$qualifiers ]
  	if { ! [string equal [self next] {}] } { next {*}$args }
  }
}

::class@::MasterClass create ::class@ {
	
	superclass ::class@::MasterClass

	variable MetaClass MasterClass
	
	constructor {{script {}}} {
		set MetaClass      [info object class [self]]
		set MasterClass    [info object class $MetaClass]
		set masterCommands [info object methods $MetaClass -all]
		set path [namespace qualifiers [self class]]
		namespace path [list {*}[namespace path] [uplevel 1 { namespace current }]]
    foreach cmd $masterCommands { my Alias $cmd [self] }
    try [ string cat $script \; [list mixin -append ::class@::MetaMixin] ] finally {
    	foreach cmd [info commands ::oo::define::*] { my Unalias $cmd }
  	}
  }
  
  method Alias {cmd callerClass args} {
  	set tail [namespace tail $cmd]
  	if { $tail eq "self" } { return }
    interp alias {} [namespace current]::$tail {} $MetaClass $tail $callerClass {*}$args
	}
	
	method Unalias { cmd } {
		set tail [namespace tail $cmd]
		if { $tail eq "self" } { return }
		::oo::define $MetaClass unexport $tail
		tailcall interp alias {} [namespace current]::$tail {}
	}
	
	method command {original cmd args} {
	  set class [info object class [self]]
	}
  
	method create {name {definition {}} args} {
		tailcall my createWithNamespace $name $name $definition {*}$args
	}

	method static {name args} {
		tailcall [namespace current]::$name {*}$args
	}
	
	method prop {name {value {}}} {
		set class [uplevel 1 {self class}]
		if { [info exists ${class}::$name] } {
			return [set ${class}::$name {*}$value]
		}
	}
	
	# link to a variable defined in the classes parent namespace.
	method nsvar {args} {
	  foreach {var value} $args {
	    uplevel 1 [list namespace upvar [namespace parent] $var $var ]
	    if { [llength $args] > 1 } {
	      uplevel 1 [list set $var $value]
	    }
	  }
	}
	
	method nsvar@ {ns args} {
	  foreach {var value} $args {
	    uplevel 1 [list namespace upvar $ns $var $var ]
	    if { [llength $args] > 1 } {
	      uplevel 1 [list set $var $value]
	    }
	  }
	}
	
	method props {{props {}} {merge 0}} {
		variable _CLASS_PROPS
		if { ! [info exists _CLASS_PROPS] } { set _CLASS_PROPS {} }
		if { $props ne {} } { set _CLASS_PROPS [expr { [string is false -strict $merge] \
			? $props  \
			: [dict merge ${_CLASS_PROPS} $props]
		} ] }
		return ${_CLASS_PROPS}
	}
	
	method define {what args} {
		switch -- $what {
			static {
				set args [lassign $args name]
				proc [namespace current]::$name {*}$args
			}
			prop {
			  lassign $args name value
			  set [namespace current]::${name} $value
			}
		}
	}
	
}