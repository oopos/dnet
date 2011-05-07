import std.algorithm, std.range, std.exception, std.conv;
import socketstream, bufferedstream, event, util;
import std.stdio;

class HttpParserException : Exception
{
  this(string msg, string file = __FILE__, size_t line = __LINE__)
  {
    super(msg, file, line);
  }
}

void _enforce(string file = __FILE__, size_t line = __LINE__)
  (int condition, string msg)
{
  if (!condition)
    throw new HttpParserException(msg, file, line);
}

struct HttpVersion
{
  ubyte major;
  ubyte minor;
}

struct HttpRequest
{
  string method;
  string uri;
  HttpVersion httpVersion;
  string[string] headers;
}

struct HttpResponse
{
  HttpVersion httpVersion;
  ushort status;
  string[string] headers;
}

HttpResponse parseHttpResponse(Stream)(Stream stream)
{
  ensureLength(stream, 5);
  _enforce(stream.front[0..5] == "HTTP/", "not HTTP");
  shiftStream(stream, 5);

  HttpResponse response;

  response.httpVersion.major = toDigit(frontThenShift(stream));
  for (;;)
  {
    auto d = frontThenShift(stream);
    if (d == '.')
      break;
    response.httpVersion.major *= 10;
    response.httpVersion.major += toDigit(d);
  }

  response.httpVersion.minor = toDigit(frontThenShift(stream));
  for (;;)
  {
    auto d = frontThenShift(stream);
    if (d == ' ')
      break;
    response.httpVersion.minor *= 10;
    response.httpVersion.minor += toDigit(d);
  }
  
  ensureLength(stream, 3);
  response.status = cast(ushort)( // Value range propagation for multiplication doesn't work
                  toDigit(stream.front[0]) * 100 +
                  toDigit(stream.front[1]) * 10 +
                  toDigit(stream.front[2]));
  
  // Skip reason phrase
  for (size_t i = 3; ; ++i)
  {
    if (i == stream.front.length)
    {
      popAndNotEmpty(stream);
      i = 0;
    }
    if (stream.front[i] == '\r')
    {
      stream.shiftFront(i + "\r\n".length);
      break;
    }
  }

  response.headers = parseHeaders(stream);
  return response;
}
  
struct HttpRequestParser(Stream)
{
private:
  Stream _stream;
  HttpRequest _request;
  bool _empty = true;

public:
  @disable this(this) {assert(0);};

  this(Stream stream)
  {
    _stream = stream;
    _empty = false;
    popFront();
  }

  @property bool empty() { return _empty; }

  @property ref HttpRequest front()
  {
    assert(!empty);
    return _request;
  }

  void popFront()
  {
    assert(!empty);

    if (!_stream.front.length)
    {
      _stream.popFront();
      if (_stream.empty)
      {
        _empty = true;
        return;
      }
    }

    for (size_t i; ; ++i)
    {
      if (i == _stream.front.length)
        _enforce(_stream.appendToFront(), "stream ended");
      if (_stream.front[i] == ' ')
      {
        _request.method = cast(string) _stream.front[0..i].idup;
        _stream.shiftFront(i + 1);
        break;
      }
    }
    
    for (size_t i; ; ++i)
    {
      if (i == _stream.front.length)
        _enforce(_stream.appendToFront(), "stream ended");
      if (_stream.front[i] == ' ')
      {
        _request.uri = cast(string) _stream.front[0..i].idup;
        _stream.shiftFront(i + 1);
        break;
      }
    }

    ensureLength(_stream, 5);
    _enforce(_stream.front[0..5] == "HTTP/", "not HTTP");
    shiftStream(_stream, 5);

    _request.httpVersion.major = toDigit(frontThenShift(_stream));
    for (;;)
    {
      auto d = frontThenShift(_stream);
      if (d == '.')
        break;
      _request.httpVersion.major *= 10;
      _request.httpVersion.major += toDigit(d);
    }

    _request.httpVersion.minor = toDigit(frontThenShift(_stream));
    for (;;)
    {
      if (!_stream.front.length)
        popAndNotEmpty(_stream);
      if (_stream.front[0] == '\r')
      {
        shiftStream(_stream, "\r\n".length);
        break;
      }
      _request.httpVersion.minor *= 10;
      _request.httpVersion.minor += toDigit(_stream.front[0]);
      _stream.shiftFront(1);
    }
    
    _enforce(_request.httpVersion == HttpVersion(1,1), "HTTP/1.1 only");

    _request.headers = parseHeaders(_stream);

    /*if (((connection = "connection" in _request.headers) &&
        *connection == "upgrade") || _request.method == "CONNECT")
    {
      handle in server
    }*/
  }
}
  
string[string] parseHeaders(Stream)(Stream stream)
{
  typeof(return) headers;
  for (;;)
  {
    if (!stream.front.length)
      popAndNotEmpty(stream);
    if (stream.front[0] == '\r')
    {
      debug
      {
        stream.shiftFront(1);  
        assert(frontThenShift(stream) == '\n');
      }
      else
        shiftStream(stream, "\r\n".length);
      break;
    }

    string headerField;
    for (size_t i; ; ++i)
    {
      if (i == stream.front.length)
        _enforce(stream.appendToFront(), "stream ended");
      if (stream.front[i] == ':')
      {
        headerField = cast(string) stream.front[0..i].idup;
        stream.shiftFront(i + 1);
        break;
      }
    }

    // Skip spaces
    for (;;)
    {
      if (!stream.front.length)
        popAndNotEmpty(stream);
      if (stream.front[0] != ' ')
        break;
      stream.shiftFront(1);
    }
    
    string headerValue;
    for (size_t i; ; ++i)
    {
      if (i == stream.front.length)
        _enforce(stream.appendToFront(), "stream ended");
      if (stream.front[i] == '\r')
      {
        headerValue = cast(string) stream.front[0..i].idup;
        stream.shiftFront(i + "\r\n".length);
        break;
      }
    }
    saveFieldValue(headers, headerField, headerValue);
  }
  return headers;
}
  
void saveFieldValue(ref string[string] headers, string field, string value)
{
  field = simpleToLower(field);
  auto v = field in headers;
  if (!v)
    headers[field] = value;
  else switch (field)
  {
    case "accept",
         "accept-charset",
         "accept-encoding",
         "accept-language",
         "connection",
         "cookie",
         "set-cookie":
      *v ~= ',' ~ value;
      break;
    default:
      if (field.length >= 2 && field[0 .. 2] == "x-")
        *v ~= ',' ~ value;
  }
}

string simpleToLower(string s)
{
  string result;
  result.reserve(s.length);
  foreach(c; s)
    result ~= (c <= 'Z') ? c | 0b10_0000 : c;
  return result;
}

unittest
{
  assert(simpleToLower("ABCdef123|Z") == "abcdef123|z");
}
  
bool isText(char c)
{
  return ' ' <= c && c != 127;
}

ubyte toDigit(char digit)
{
  digit -= '0';
  _enforce(digit < 10, "expected a number");
  return digit;
}

struct ContentReader(Stream)
{
  struct Chunk
  {
    @disable this(this) {assert(0);};

    this(Stream stream, ulong length)
    {
      _stream = stream;
      _totalLength = _remaining = length;
      _empty = false;
    }

    this(Stream stream, const char[] packet)
    {
      _stream = stream;
      _packet = packet;
      _totalLength = _remaining = packet.length;
      _empty = false;
    }

    @property ulong totalLength() {return _totalLength;}
    @property bool empty() {return _empty;}

    @property const(char)[] front()
    {
      assert(!empty);
      return _packet;
    }

    void popFront()
    {
      assert(!empty);

      _stream.shiftFront(_packet.length);
      _remaining -= _packet.length;
      if (!_remaining)
      {
        _empty = true;
        return;
      }
      if (!_stream.front.length)
        popAndNotEmpty(_stream);
      size_t toRead = min(_stream.front.length, _remaining);
      _packet = cast(char[]) _stream.front[0..toRead];
    }

  private:
    const(char)[] _packet;
    ulong _totalLength;
    ulong _remaining;
    Stream _stream;
    bool _empty = true;
  }

  private Chunk _chunk;
  string[string] trailingHeaders;
  @disable this(this) {assert(0);};
  
  this(Stream stream)
  {
    _stream = stream;
  }

  void setContentLength(ulong length)
  {
    _chunk = Chunk(_stream, length);
    _empty = false;
  }

  void setChunked()
  {
    _popFrontImpl = &popFront_chunked;
    _empty = false;
  }

  void setReadUntilTerminated()
  {
    _popFrontImpl = &popFront_untilTerminated;
    _empty = false;
  }

  @property bool empty() {return _empty;}

  @property ref Chunk front()
  {
    assert(!empty);
    return _chunk;
  }

  void popFront()
  {
    assert(!empty);
    _popFrontImpl(this);
  }

  static void popFront_knownContentLength(ref typeof(this) self)
  {
    with (self)
    {
      // Present a single chunk
      while (!_chunk.empty) _chunk.popFront();
      _empty = true;
    }
  }

  static void popFront_untilTerminated(ref typeof(this) self)
  {
    with (self)
    {
      if (!_chunk.empty || !_stream.front.length)
      {
        _stream.popFront();
        if (_stream.empty)
        {
          _empty = true;
          return;
        }
      }
      _chunk = Chunk(_stream, cast(char[]) _stream.front);
    }
  }

  static void popFront_chunked(ref typeof(this) self)
  {
    with (self)
    {
      while (!_chunk.empty) _chunk.popFront();

      if (_firstChunk)
        _firstChunk = false;
      else
        shiftStream(_stream, "\r\n".length);

      byte h = unhex[frontThenShift(_stream)];
      _enforce(h != -1, "the chunk didn't start with a length");
      ulong chunkSize = h;
      for (size_t i; ; ++i)
      {
        if (i == _stream.front.length)
        {
          popAndNotEmpty(_stream);
          i = 0;
        }
        h = unhex[_stream.front[i]];
        if (h == -1)
        {
          _stream.shiftFront(i + 1);
          break;
        }
        chunkSize *= 16;
        chunkSize += h;
      }
      
      // Ignore chunk parameters
      while (frontThenShift(_stream) != '\n') {}

      if (chunkSize == 0)
      {
        trailingHeaders = parseHeaders(_stream);
        _empty = true;
        return;
      }

      _chunk = Chunk(_stream, chunkSize);
    }
  }

  Stream _stream;
  auto _popFrontImpl = &popFront_knownContentLength;
  bool _firstChunk = true;
  bool _empty = true;
}

private immutable byte[256] unhex =
  [-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
  ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
  ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
  , 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,-1,-1,-1,-1,-1,-1
  ,-1,10,11,12,13,14,15,-1,-1,-1,-1,-1,-1,-1,-1,-1
  ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
  ,-1,10,11,12,13,14,15,-1,-1,-1,-1,-1,-1,-1,-1,-1
  ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
  ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
  ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
  ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
  ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
  ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
  ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
  ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
  ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
  ];