import std.container, std.algorithm, std.conv, std.date, std.exception,
       core.sys.posix.unistd, epoll, core.stdc.errno, event;
import std.stdio;

EventLoop eventLoop; // Each thread gets its own global EventLoop;

static this()
{
  eventLoop = new EventLoop;
}

final class EventLoop
{
  enum
  {
    IN = EPOLLIN,
    OUT = EPOLLOUT,
    END = EPOLLRDHUP,
    ERROR = EPOLLERR | EPOLLHUP
  }
  
  struct EventInfo
  {
    void delegate(int) callback;
    int events;
  }
  
  struct Timeout
  {
    this(void delegate() callback, long time)
    {
      this.callback = callback;
      this.time = time;
    }
    
    void delegate() callback;
    long time;
  }
  
  this()
  {
    _fd = epoll_create1(0);
    enforce(_fd >= 0, new ErrnoException("epoll_create1"));
  }
  
  ~this()
  {
    close();
  }

  void run()
  {
    epoll_event[MAX_EVENTS] ebuf;
    _running = true;
    for (;;)
    { 
      onNextIteration();
      if (!_running)
        return;     
      auto nextTimeout = _timeoutQueue.empty ? -1 :
          max!int(cast(int)(_timeoutQueue.front.time - getUTCtime()), 0); // FIXME
      int count = epoll_wait(_fd, &ebuf[0], MAX_EVENTS, nextTimeout);
      if (count >= 0)
      {
        foreach (i; 0 .. count)
        {
          int fd = ebuf[i].data.fd;
          int events = ebuf[i].events;
          debug writeln("Event ", events, " by fd ", fd);
          _eventInfo[fd].callback(events);
        }
      }
      else
      {
        if (errno == EINTR)
        {
          if (nextTimeout != -1)
          {
            enforce(nextTimeout != -1,
              "Unexpected interruption of epoll_wait.");
            _timeoutInsertMayReplace = true;
            _timeoutQueue.front.callback();
            if (_timeoutInsertMayReplace) // no one inserted a new timeout
              _timeoutQueue.removeFront();
          }
        }
        else
          throw new ErrnoException("epoll_wait");
      }
    }
  }
  
  void stop()
  {
    _running = false;
  }
  
  void add(int fd, int events, void delegate(int) callback)
  {
    assert(fd != -1);
    
    if (_eventInfo.length <= fd)
    {
      _eventInfo.length = fd + 1;
      debug writeln("Eventloop fd capacity expanded to ", fd);
    }

    epoll_event ev;
    ev.data.fd = fd;
    ev.events = events;
    int ret = epoll_ctl(_fd, EPOLL_CTL_ADD, fd, &ev);
    enforce(ret == 0, new ErrnoException("EPOLL_CTL_ADD"));
    _eventInfo[fd].events = events;
    _eventInfo[fd].callback = callback;
  }
  
  void modify(int fd, int events, void delegate(int) callback)
  {
    epoll_event ev;
    ev.data.fd = fd;
    ev.events = events;
    int ret = epoll_ctl(_fd, EPOLL_CTL_MOD, fd, &ev);
    enforce(ret == 0, new ErrnoException("EPOLL_CTL_MOD"));
    _eventInfo[fd].events = events;
    _eventInfo[fd].callback = callback;
  }
  
  void modifyOnce(int fd, int events, void delegate(int) callback)
  {
    debug writeln("modifyOnce ", fd);
    modify(fd, events | EPOLLONESHOT, callback);
  }
  
  void remove(int fd)
  {
    debug writeln("eventloop remove");
    _eventInfo[fd] = EventInfo.init;
    int ret = epoll_ctl(_fd, EPOLL_CTL_DEL, fd, null);
    enforce(ret == 0, new ErrnoException("EPOLL_CTL_DEL"));
  }
  
  int getRegisteredEvents(int fd)
  {
    return _eventInfo[fd].events;
  }
  
  void close()
  {
    if (_fd != -1)
    {
      .close(_fd);
      _fd = -1;
    }
  }
  
  void setTimeout(uint milliseconds, void delegate() callback)
  {
    long absoluteTime = getUTCtime() + milliseconds;
    if (_timeoutInsertMayReplace)
    {
      _timeoutInsertMayReplace = false;
      Timeout* front = _timeoutQueue.front;
      front.callback = callback;
      front.time = absoluteTime;
      _timeoutQueue.replaceFront(front);
    }
    else
      _timeoutQueue.insert(new Timeout(callback, absoluteTime));
  }
  
  Notification!() onNextIteration;

  private:
  enum MAX_EVENTS = 10;
  int _fd = -1;
  EventInfo[] _eventInfo;
  alias BinaryHeap!(Timeout*[], q{a.time > b.time}) TimeoutQueue;
  TimeoutQueue _timeoutQueue;
  bool _running;
  bool _timeoutInsertMayReplace;
}

