import std.algorithm, std.range, std.exception, std.conv;
import socketstream, bufferedstream, event, util;
import std.stdio;

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

alias Event!(const(char)[]) HttpContentEvent;
alias Event!() HttpEndEvent;

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
  HttpContentEvent onContent;
  HttpEndEvent onEnd;
}

struct HttpResponse
{
  HttpVersion httpVersion;
  ushort status;
  string[string] headers;
  HttpContentEvent onContent;
}

alias void delegate(ref HttpRequest) HttpRequestOnlyHandler;
alias void delegate(ref HttpResponse) HttpResponseHandler;

void parseHttpRequest(S)(S stream, scope HttpRequestOnlyHandler onRequest)
{
  HttpParser!S(stream).parseRequest(onRequest);
}

void parseHttpResponse(S)(S stream, scope HttpResponseHandler onResponse)
{
  HttpParser!S(stream).parseResponse(onResponse);
}

private struct HttpParser(S)
{
  S stream;

  void parseResponse(scope HttpResponseHandler onResponse)
  {
    ensureLength(stream, 5);
    _enforce(stream.front[0..5] == "HTTP/", "not HTTP");
    shiftStream(stream, 5);

    HttpVersion httpVersion;
    httpVersion.major = toDigit(frontThenShift(stream));
    for (;;)
    {
      auto d = frontThenShift(stream);
      if (d == '.')
        break;
      httpVersion.major *= 10;
      httpVersion.major += toDigit(d);
    }

    httpVersion.minor = toDigit(frontThenShift(stream));
    for (;;)
    {
      auto d = frontThenShift(stream);
      if (d == ' ')
        break;
      httpVersion.minor *= 10;
      httpVersion.minor += toDigit(d);
    }
    
    ensureLength(stream, 3);
    ushort status = cast(ushort)( // Value range propagation for multiplication doesn't work
                    toDigit(stream.front[0]) * 100
                  + toDigit(stream.front[1]) * 10
                  + toDigit(stream.front[2]));
    
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
    
    string[string] headers;
    parseHeaders(headers);
    auto response = HttpResponse(httpVersion, status, headers);
    onResponse(response);
    
    string* transferEncoding = "transfer-encoding" in headers;
    if (transferEncoding && simpleToLower(*transferEncoding) == "chunked")
    { 
      readChunked(response.onContent, headers); // Trailing headers are simply added to the rest
    }
    else
    {
      string* contentLengthStr = "content-length" in headers;
      if (contentLengthStr)
      {
        ulong contentLength;
        try
          contentLength = to!ulong(*contentLengthStr);
        catch(ConvException)
          throw new HttpParserException("invalid Content-Length");
        
        readContent(contentLength, response.onContent);
      }
      else // Neither chunked nor content-length
      {
        assert(0, "not implemented");
      }
    }
  }
  
  void parseRequest(scope HttpRequestOnlyHandler onRequest)
  {
    for (;;) // Parse a message
    {
      if (!stream.front.length)
      {
        stream.popFront();
        if (stream.empty)
          return;
      }

      string method;
      for (size_t i; ; ++i)
      {
        if (i == stream.front.length)
          _enforce(stream.appendToFront(), "stream ended");
        if (stream.front[i] == ' ')
        {
          method = cast(string) stream.front[0..i].idup;
          stream.shiftFront(i + 1);
          break;
        }
      }
      
      string uri;
      for (size_t i; ; ++i)
      {
        if (i == stream.front.length)
          _enforce(stream.appendToFront(), "stream ended");
        if (stream.front[i] == ' ')
        {
          uri = cast(string) stream.front[0..i].idup;
          stream.shiftFront(i + 1);
          break;
        }
      }

      ensureLength(stream, 5);
      _enforce(stream.front[0..5] == "HTTP/", "not HTTP");
      shiftStream(stream, 5);
      HttpVersion httpVersion;
      httpVersion.major = toDigit(frontThenShift(stream));
      for (;;)
      {
        auto d = frontThenShift(stream);
        if (d == '.')
          break;
        httpVersion.major *= 10;
        httpVersion.major += toDigit(d);
      }

      httpVersion.minor = toDigit(frontThenShift(stream));
      for (;;)
      {
        if (!stream.front.length)
          popAndNotEmpty(stream);
        if (stream.front[0] == '\r')
        {
          shiftStream(stream, "\r\n".length);
          break;
        }
        httpVersion.minor *= 10;
        httpVersion.minor += toDigit(stream.front[0]);
        stream.shiftFront(1);
      }
      
      string[string] headers;
      parseHeaders(headers);
      auto request = HttpRequest(method, uri, httpVersion, headers);
      onRequest(request);
      string* connection, transferEncoding;
      if (connection = "connection" in headers,
        (connection && *connection == "upgrade") || method == "CONNECT")
      {
        // Exit, the rest of the connection is in a different protocol.
      }
      else if (transferEncoding = "transfer-encoding" in headers,
        transferEncoding && simpleToLower(*transferEncoding) == "chunked")
      {
        readChunked(request.onContent, headers); // Trailing headers are simply added to the rest
      }
      else
      {
        string* contentLengthStr = "content-length" in headers;
        ulong contentLength;
        if (contentLengthStr)
        {
          try
            contentLength = to!ulong(*contentLengthStr);
          catch(ConvException)
            throw new HttpParserException("invalid Content-Length");
          
          readContent(contentLength, request.onContent);
        }
        else // Neither chunked nor content-length
        {
          // Assume content-length 0
        }
      }
      request.onEnd(); 
    }
  }
  
  void parseHeaders(ref string[string] headers)
  {
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

  void readChunked(HttpContentEvent onContent, ref string[string] headers)
  {
    for (;;)
    {
      byte h = unhex[frontThenShift(stream)];
      _enforce(h != -1, "the chunk didn't start with a length");
      ulong chunkSize = h;
      for (size_t i; ; ++i)
      {
        if (i == stream.front.length)
        {
          popAndNotEmpty(stream);
          i = 0;
        }
        h = unhex[stream.front[i]];
        if (h == -1)
        {
          stream.shiftFront(i + 1);
          break;
        }
        chunkSize *= 16;
        chunkSize += h;
      }
      
      // Ignore chunk parameters
      while (frontThenShift(stream) != '\n') {}
      
      if (chunkSize == 0)
        break;

      readContent(chunkSize, onContent);
      shiftStream(stream, "\r\n".length);
    }
    parseHeaders(headers);
  }
  
  void readContent(ulong n, HttpContentEvent onContent)
  {
    if (!stream.front.length)
      popAndNotEmpty(stream);
    while (n > stream.front.length)
    {
      onContent(cast(const char[]) stream.front);
      n -= stream.front.length;
      popAndNotEmpty(stream);
    }
    onContent(cast(const char[]) stream.front[0 .. cast(size_t) n]);
    stream.shiftFront(cast(size_t) n);
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