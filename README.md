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