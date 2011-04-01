import std.exception, core.stdc.errno;

T syscallEnforce(T, string file = __FILE__, uint line = __LINE__)
  (T val, string msg)
{
  if (val == -1)
    throw new ErrnoException(msg, file, line);
  return val;
}

T interruptibleSyscall(T)
  (lazy T call, string msg, string file = __FILE__, uint line = __LINE__)
{
  start:
  T ret = call();
  if (ret == -1)
  {
    if (errno == EINTR)
      goto start;
    throw new ErrnoException("intrSyscall, "~msg, file, line);
  }
  return ret;
}