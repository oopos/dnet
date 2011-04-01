import std.exception: enforce;
import std.algorithm: min;
import std.stdio;

struct SocketStream(SocketT)
{
  SocketT socket;
  ubyte[] buf;

  @property
  {
    ubyte[] front()
    {
      return _unread;
    }
    
    bool empty()
    {
      return _empty;
    }
  }
  
  void popFront()
  {
    size_t nRead = socket.recv(buf);
    _unread = buf[0..nRead];
    if (nRead == 0)
      _empty = true;
  }
  
  void shiftFront(size_t n)
  {
    assert(n <= _unread.length);
    _unread = _unread[n..$];
  }

  size_t appendToFront(size_t n = 0)
  {
    assert(_unread.ptr);
    ubyte[] freeSpace = buf[_unread.ptr-buf.ptr+_unread.length..$];
    if (n == 0)
    {
      if (!freeSpace.length)
      {
        enforce(_unread.length < buf.length, "buffer overflow");
        buf[0.._unread.length] = _unread;
        _unread = buf[0.._unread.length];
        freeSpace = buf[_unread.length..$];
      }
    }
    else
    {
      if (n > freeSpace.length)
      {
        enforce(_unread.length + n <= buf.length, "buffer overflow");
        buf[0.._unread.length] = _unread;
        _unread = buf[0.._unread.length];
        freeSpace = buf[_unread.length..$];
      }
    }
    size_t total;
    for (;;)
    {
      size_t nRead = socket.recv(freeSpace);
      total += nRead;
      if (total >= n || nRead == 0)
      {
        _unread = _unread.ptr[0.._unread.length+total];
        return total;
      }
    }
  }

  /*size_t appendToFront(size_t n = 0)
  {
    assert(_unread.ptr);
    ubyte[] freeSpace = buf[_unread.ptr-buf.ptr+_unread.length..$];
    if (n == 0)
    {
      if (!freeSpace.length)
      {
        enforce(_unread.length < buf.length, "buffer overflow");
        buf[0.._unread.length] = _unread;
        _unread = buf[0.._unread.length];
        freeSpace = buf[_unread.length..$];
      }
    }
    else
    {
      if (n <= freeSpace.length)
        freeSpace = freeSpace[0..n];
      else
      {
        enforce(_unread.length + n <= buf.length, "buffer overflow");
        buf[0.._unread.length] = _unread;
        _unread = buf[0.._unread.length];
        freeSpace = (buf.ptr+_unread.length)[0..n];
      }
    }
    size_t nRead = socket.recv(freeSpace);
    _unread = _unread.ptr[0.._unread.length+nRead];
    return nRead;
  }*/

  private:
  ubyte[] _unread;
  bool _empty;
}