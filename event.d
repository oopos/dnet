module event;

struct Event(Args...)
{  
  alias void delegate(Args) DelegateType;
  
  void opCall(Args args)
  {
    if (callback)
      callback(args);
  }
  
  void opAssign(DelegateType callback)
  {
    this.callback = callback;
  }
  
  DelegateType callback;
}

unittest
{
  Event!() onEvent;
  onEvent(); // Ignores calls to null
  int a;
  onEvent = {a++;};
  onEvent();
  assert(a == 1);
}

struct Notification(Args...)
{
  alias void delegate(Args) DelegateType;
  
  void opCall(Args args)
  {
    foreach (cb; callbacks)
      cb(args);
    callbacks.length = 0;
  }
  
  void opOpAssign(string op, T)(T callback)
      if (op == "~" && is(T == DelegateType))
  {
    callbacks ~= callback;
  }
  
  void opOpAssign(string op, T)(ref T functor)
      if (op == "~" && !is(T == DelegateType))
  {
    callbacks ~= &functor.opCall;
  }

  private DelegateType[] callbacks;
}

unittest
{
  Notification!() asap;
  int a = 5;
  int b;
  asap ~= {b += 2;};
  Event!() onEvent;
  asap ~= onEvent;
  onEvent = {a *= b;};
  asap();
  assert(a == 10);
  asap(); // Registered callbacks already notified, so do nothing
  assert(a == 10);
}
