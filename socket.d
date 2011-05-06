import std.exception;
public import core.sys.posix.sys.socket, core.sys.posix.netinet.in_;
import core.sys.posix.unistd, core.sys.posix.fcntl, core.thread,
       core.stdc.errno;
import eventloop, syscall, util;
import std.stdio;

version(linux)
{
  alias O_NONBLOCK SOCK_NONBLOCK;
  enum MSG_MORE = 0x8000;
}

template isSocketAddress(T)
{
  enum isSocketAddress = is(T == sockaddr_in)
                      // || is(T == sockaddr_un)
                      || is(T == sockaddr);
}

struct SyncSocket
{
  mixin SocketCommon;
  
  this(int domain, int type, int protocol)
  {
    create(domain, type, protocol);
  }
  
  void create(int domain, int type, int protocol)
  {
    _fd = syscallEnforce(.socket(domain, type, protocol), "socket");
  }

  void close()
  {
    int fd = _fd;
    _fd = -1;
    _close(fd);
  }
  
  size_t send(in ubyte[] data, int flags = 0)
  {
    return interruptibleSyscall(
      .send(_fd, data.ptr, data.length, flags),
      "send");
  }
  
  size_t sendmsg(ref msghdr msg, int flags = 0)
  {
    return interruptibleSyscall(
      .sendmsg(_fd, &msg, flags),
      "sendmsg");
  }
  
  size_t recv(ubyte[] data, int flags = 0)
  {
    return interruptibleSyscall(
      .recv(_fd, data.ptr, data.length, flags),
      "recv");
  }
  
  SyncSocket accept()
  {
    int fd = interruptibleSyscall(
      .accept(_fd, null, null),
      "accept");
    SyncSocket newSocket;
    newSocket._fd = fd;
    return newSocket;
  }
  
  void connect(Addr)(ref Addr addr) if(isSocketAddress!Addr)
  {
    interruptibleSyscall(
      .connect(_fd, cast(sockaddr*) &addr, addr.sizeof),
      "connect");   
  }
}

struct AsyncSocket
{
  mixin SocketCommon;

  this(int domain, int type, int protocol)
  {
    create(domain, type, protocol);
  }

  void create(int domain, int type, int protocol)
  {
    int fd = syscallEnforce(
      .socket(domain, type | SOCK_NONBLOCK, protocol),
      "socket");
    scope(failure) _close(fd);
    eventLoop.add(fd, 0, null);
    _fd = fd;
  }
  
  void close()
  {
    debug writeln("Closing socket ", _fd);
    int fd = _fd;
    _fd = -1;
    scope(exit) _close(fd);
    eventLoop.remove(fd);
  }
  
  size_t send(in ubyte[] data, int flags = 0)
  {
    return noblockSyscall(
      .send(_fd, data.ptr, data.length, flags),
      EventLoop.OUT,
      "send");
  }
  
  size_t sendmsg(ref msghdr msg, int flags = 0)
  {
    return noblockSyscall(
      .sendmsg(_fd, &msg, flags),
      EventLoop.OUT,
      "sendmsg");
  }
  
  size_t recv(ubyte[] data, int flags = 0)
  {
    return noblockSyscall(
      .recv(_fd, data.ptr, data.length, flags),
      EventLoop.IN,
      "recv");
  }
    
  AsyncSocket accept()
  {
    int fd = noblockSyscall(
      .accept(_fd, null, null),
      EventLoop.IN,
      "accept");
    scope(failure) _close(fd);
    int x = syscallEnforce(fcntl(fd, F_GETFL, 0), "fcntl F_GETFL");
    x |= O_NONBLOCK;
    syscallEnforce(fcntl(fd, F_SETFL, x), "fcntl F_SETFL");
    eventLoop.add(fd, 0, null);
    AsyncSocket newSocket;
    newSocket._fd = fd;
    return newSocket;
  }
  
  void connect(Addr)(ref Addr addr) if(isSocketAddress!Addr)
  {
    start:
    if (.connect(_fd, cast(sockaddr*) &addr, addr.sizeof) == -1)
    {
      if (errno == EINPROGRESS)
      {
        yield(EventLoop.OUT);
        if (getOption(SO_ERROR))
          throw new Exception("connect failed "~
            "after yielding to EINPROGRESS");
      }
      else if (errno == EINTR)
        goto start;
      else
        throw new ErrnoException("connect", __FILE__, __LINE__);
    }
  }
  
private:
  void yield(int events)
  {
    auto thisFiber = Fiber.getThis();
    eventLoop.modifyOnce(_fd, events,
      scopeDelegate((int){thisFiber.call();}));
    Fiber.yield();
  }

  T noblockSyscall(T)
    (lazy T call, int events, string msg,
    string file = __FILE__, uint line = __LINE__)
  {
    start:
    T ret = call();
    if (ret == -1)
    {
      if (errno == EAGAIN)
      {
        yield(events);
        goto start;
      } 
      if (errno == EINTR)
        goto start;
      throw new ErrnoException("noblockSyscall, "~msg, file, line);
    }
    return ret;
  }
  
  /*void _onEvent(int events)
  {
    _thisFiber.call();
  }*/
}

private mixin template SocketCommon()
{
  void listen(int backlog)
  {
    syscallEnforce(.listen(_fd, backlog), "listen");
  }
  
  void bind(Addr)(ref Addr addr) if(isSocketAddress!Addr)
  {
    syscallEnforce(.bind(_fd, cast(sockaddr*) &addr, addr.sizeof), "bind");
  }
  
  void shutdown(int how)
  {
    syscallEnforce(.shutdown(_fd, how), "shutdown");
  }
  
  void setOption(int optname, int value)
  {
    syscallEnforce(
      .setsockopt(_fd, SOL_SOCKET, optname, &value, int.sizeof),
      "setsockopt");
  }
  
  int getOption(int optname)
  {
    int value;
    socklen_t size = int.sizeof;
    syscallEnforce(
      .getsockopt(_fd, SOL_SOCKET, optname, &value, &size),
      "getsockopt");
    return value;
  }
  
  /*void sendAll(N)(int flags, in ubyte[][N] buffers...)
  {
    size_t totalLength;
    iovec[N] iov = void;*/
  void sendAll(int flags, in ubyte[][] buffers...)
  {
    size_t totalLength;
    iovec[] iov = new iovec[buffers.length];
    
    foreach (i, b; buffers)
    {
      totalLength += b.length;
      iov[i].iov_base = cast(void*) b.ptr;
      iov[i].iov_len = b.length;
    }
      
    msghdr msg;
    msg.msg_iov = iov.ptr;
    msg.msg_iovlen = iov.length;

    auto nSent = sendmsg(msg, flags);
    if (nSent != totalLength)
      throw new Error("sendmsg was interrupted by a signal");
  }

  int fd() @property {return _fd;}
  bool isOpen() @property {return _fd != -1;}
  
private:
  int _fd = -1;
}

private void _close(int fd)
{
  interruptibleSyscall(.close(fd), ".close");
}