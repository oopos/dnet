import std.stdio, std.exception, std.typecons, std.conv, std.c.stdlib,
       std.array, std.string, std.datetime, 
       core.thread, core.sys.posix.arpa.inet, core.sys.posix.signal,
       core.sys.posix.poll, core.stdc.errno;
import socket, socketstream, httpparser, allocator, eventloop, util;
public import httpparser: HttpRequest, HttpResponse, ContentReader;

enum PAGESIZE = 4096;
enum BUFFERSIZE = PAGESIZE;

static this()
{
  sigaction_t sa;
  sa.sa_handler = SIG_IGN;
  sigaction(SIGPIPE, &sa, null);
}

struct HttpServer
{ 
  struct Conversation
  {
    HttpPeer!AsyncSocket _peer;
    alias _peer this;

    @disable this(this) {assert(0);};

    private this(AsyncSocket socket)
    {
      _peer._socket = socket;
    }

    void respond(ushort status, string[string] headers)
    {
      headers["Date"] = formatDateTime(Clock.currTime);
      _peer.sendMessage("HTTP/1.1 "~statusStrings[status], headers);
    }

    void stockResponse(ushort status)
    {
      string message = statusStrings[status][0..$-2]; // strip away \r\n
      string html =
        "<!DOCTYPE html><html><head><title>"~message~"</title></head>"~
        `<body style="text-align:center"><h1>`~message~"</h1></body></html>";
      respond(status, ["Content-Length": to!string(html.length)]);
      _peer.sendContent(html);
    }
  }

  alias void delegate(HttpRequest, ref Conversation) RequestHandler;
  // Scope correct?

  @disable this(this) {assert(0);};

  this(ushort port)
  {
    create(port);
  }
  
  ~this() 
  {
    if (_socket.isOpen)
      close();
  }
  
  void create(ushort port)
  {
    _socket.create(AF_INET, SOCK_STREAM, 0);
    _socket.setOption(SO_REUSEADDR, 1);
    auto sin = sockaddr_in(AF_INET, htons(port), in_addr(INADDR_ANY));
    _socket.bind(sin);
    _socket.listen(-1); // linux SOMAXCONN
  }
  
  void stop()
  {
    _stop = true; // Stop at next request
  }
  
  void close()
  {
    _socket.close();
  }
  
  void start()
  {
    (new Fiber(&accept)).call();
  }

  @property uint connections() {return _connections;}
  uint maxConnections = uint.max;
  RequestHandler onRequest;
  
  private:
  void accept()
  {
    while(!_stop)
    {
      auto newSock = _socket.accept();
      debug writeln(newSock.fd, " accept()ed");
      if (_connections < maxConnections)
      {
        (new Fiber(scopeDelegate( // We move newSock right away,
        {                         // so scopeDelegate is safe
          auto fibSock = newSock;
          ++_connections;
          debug writeln("connections: ", _connections);
          ubyte* buf = cast(ubyte*) _bufAllocator.allocate();

          try
          {
            alias SocketStream!AsyncSocket Stream;
            auto stream = Stream(fibSock, buf[0..BUFFERSIZE]);
            auto conversation = Conversation(fibSock);
            foreach (ref request; HttpRequestParser!(Stream*)(&stream))
            {
              while (!conversation.receivedContent.empty)
                conversation.receivedContent.popFront(); // purge unread content
              conversation.receivedContent = ContentReader!(Stream*)(&stream);
      
              string* transferEncoding, contentLengthStr;
              if (transferEncoding = "transfer-encoding" in request.headers,
                transferEncoding && simpleToLower(*transferEncoding) != "identity")
              {
                conversation.receivedContent.setChunked();
              }
              else if (contentLengthStr = "content-length" in request.headers,
                contentLengthStr)
              {
                ulong length;
                try
                  length = to!ulong(*contentLengthStr);
                catch(ConvException)
                  throw new HttpParserException("invalid Content-Length");
                
                conversation.receivedContent.setContentLength(length);
              }

              try onRequest(request, conversation);
              catch (Exception e)
              {
                writeln("500: ", e);
                conversation.stockResponse(Status.InternalServerError);
              }
            }
          }
          catch (Exception e) 
          {
            writeln("Error in fd ", fibSock.fd, ": ", e.msg);
          }

          _bufAllocator.deallocate(buf);
          --_connections;         
          debug writeln(fibSock.fd, " close()d");
          fibSock.close();
        }
        ), PAGESIZE)).call();
      }
      else
        newSock.close();
    }
    _stop = false;
  }
  
  AsyncSocket _socket;
  uint _connections;
  bool _stop;
  ExactFreeList!(BUFFERSIZE, Mallocator, true) _bufAllocator;
}

alias BasicHttpClient!SyncSocket HttpClient;
alias BasicHttpClient!AsyncSocket HttpClientAsync;

struct BasicHttpClient(Socket, size_t BUFFERSIZE = PAGESIZE)
{
  HttpPeer!Socket _peer;
  alias _peer this;

  @disable this(this) {assert(0);};

  this(uint ip, ushort port)
  {
    setAddress(ip, port);
  }

  ~this()
  {
    if (_peer._socket.isOpen)
      close();
  }

  void close()
  {
    assert(_peer._socket.isOpen);
    _bufAllocator.deallocate(_buf);
    _buf = null;
    _peer._socket.close();
  }

  void setAddress(uint ip, ushort port)
  {
    _sin = sockaddr_in(AF_INET, htons(port), in_addr(htonl(ip)));
  }

  void request(string method, string uri, string[string] headers)
  {
    ensureConnection();
    _peer.sendMessage(method~' '~uri~" HTTP/1.1\r\n", headers);
    if (method == "HEAD")
      _expectingHEADResponse = true;
  }
  
  HttpResponse getResponse()
  {
    while (!_peer.receivedContent.empty) // purge unread content
      _peer.receivedContent.popFront();
    _peer.receivedContent = ContentReader!(Stream*)(&_stream);

    HttpResponse response = parseHttpResponse(&_stream);
    string* transferEncoding, contentLengthStr;

    if (_expectingHEADResponse)
    {
      // No content even if headers indicate otherwise
      _expectingHEADResponse = false;
    }
    else if (response.status < 200 || // 1xx, informational
             response.status == Status.NoContent ||
             response.status == Status.NotModified)
    {
      // No content even if headers indicate otherwise
    }
    else if (transferEncoding = "transfer-encoding" in response.headers,
             transferEncoding && simpleToLower(*transferEncoding) != "identity")
    {
      // Chunked encoding
      _peer.receivedContent.setChunked();
    }
    else if (contentLengthStr = "content-length" in response.headers,
             contentLengthStr)
    {
      // Known content length
      ulong length;
      try length = to!ulong(*contentLengthStr);
      catch(ConvException)
        throw new HttpParserException("invalid Content-Length");
      _peer.receivedContent.setContentLength(length);
    }
    else
    {
      // The server will terminate the message body by closing the connection
      _peer.receivedContent.setReadUntilTerminated();
    }

    return response;
  }
  
  private:  
  void ensureConnection()
  {
    /*version(linux)
      enum POLLRDHUP = 0x2000;
    auto pfd = pollfd(_socket.fd, cast(short) 0xffff); // all events
    syscallEnforce(poll(&pfd, 1, 0), "poll");*/
    
    if (!_peer._socket.isOpen)
    {
      _peer._socket.create(AF_INET, SOCK_STREAM, 0);
      scope(failure) _peer._socket.close();
      _peer._socket.connect(_sin);
      _buf = cast(ubyte*) _bufAllocator.allocate();
      _stream = Stream(_peer._socket, _buf[0..BUFFERSIZE]); // What happens to this when empty?
      return;
    }

    version(linux) enum MSG_DONTWAIT = 0x40;
    
    ubyte buf;
    recvAgain:
    auto ret = recv(_peer._socket.fd, &buf, 1, MSG_DONTWAIT);
    if (ret == -1)
    {
      if (errno == EAGAIN)
        return;
      if (errno == EINTR)
        goto recvAgain;
      throw new ErrnoException("recv", __FILE__, __LINE__);
    }

    if (ret == 0)
    {
      debug writeln("Disconnected, reconnecting.");
      scope(failure)
      {
        _bufAllocator.deallocate(_buf);
        _buf = null;
      }
      _peer._socket.close();
      _peer._socket.create(AF_INET, SOCK_STREAM, 0);   
      scope(failure) _peer._socket.close();
      _peer._socket.connect(_sin);
      _stream = Stream(_peer._socket, _buf[0..BUFFERSIZE]); // What happens to this when empty?
    }
    else if (ret == 1)
    {
      scope(exit) close();
      throw new Exception("HttpClient: Unexpected data from server");
    }
  }
  
  alias SocketStream!Socket Stream;
  sockaddr_in _sin;
  Stream _stream;
  static ExactFreeList!(BUFFERSIZE, Mallocator, true) _bufAllocator;
  ubyte* _buf;
  bool _expectingHEADResponse;
}

private struct HttpPeer(Socket)
{
  alias SocketStream!Socket Stream;
  ContentReader!(Stream*) receivedContent;
  
  void sendContent(in char[] chunk)
  {
    send(chunk);
  }
  
  void sendChunk(in char[] chunk)
  { // Allowed to send an empty chunk?
    send(hex(chunk.length), "\r\n", chunk, "\r\n");
  }
  
  void endChunked()
  {
    send("0\r\n\r\n");
  }
  
  void endChunked(string[string] trailers)
  {
    string trailersStr = "0\r\n";
    foreach (field, value; trailers)
      trailersStr ~= field ~ ": " ~ value ~ "\r\n";
    trailersStr ~= "\r\n";
    send(trailersStr);
  }
  
private:
  Socket _socket;

  void sendMessage(string firstline, string[string] headers)
  {
    string headersStr;
    foreach (field, value; headers)
      headersStr ~= field~": "~value~"\r\n";
    headersStr ~= "\r\n";
    
    if ("content-length" in headers)
      sendCorked(firstline, headersStr);
    else
      send(firstline, headersStr);
  }

  void send(in char[][] chunks...)
  {
    _socket.sendAll(0, cast(const ubyte[][]) chunks);
  }
  
  void sendCorked(in char[][] chunks...)
  {
    _socket.sendAll(MSG_MORE, cast(const ubyte[][]) chunks);
  }
}

string joinContent(Stream)
  (ref ContentReader!Stream content, size_t maxLength = 256*1024)
{
  Appender!string a;
  for(; !content.empty; content.popFront())
  {
    content.Chunk* chunk = &content.front();
    ulong newLength = a.capacity + chunk.totalLength;
    enforce(newLength <= maxLength, "max content length exceeded");
    a.reserve(cast(size_t) newLength);
    for (; !chunk.empty; chunk.popFront())
      a.put(chunk.front);
  }
  return a.data;
}

/*string formatDateTime(SysTime time)
{
  // RFC 2616 3.3.1
  static immutable string[] days =
    ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  static immutable string[] months =
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  time.timezone = UTC();
  return format("%s, %02d %s %04d %02d:%02d:%02d GMT",
                days[time.dayOfWeek],
                time.day, months[time.month-1], time.year,
                time.hour, time.minute, time.second);
}*/

string formatDateTime(SysTime time)
{
  // RFC 2616 3.3.1
  static immutable string[] days =
    ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  static immutable string[] months =
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  time.timezone = UTC();

  auto result = uninitializedArray!char(29);
  result[0..3] = days[time.dayOfWeek];
  result[3..5] = ", ";
  auto day = time.day;
  result[5] = cast(char)('0' + day / 10);
  result[6] = cast(char)('0' + day % 10);
  result[7] = ' ';
  result[8..11] = months[time.month-1];
  result[11] = ' ';
  auto year = time.year;
  result[15] = cast(char)('0' + year % 10);
  year /= 10;
  result[14] = cast(char)('0' + year % 10);
  year /= 10;
  result[13] = cast(char)('0' + year % 10);
  result[12] = cast(char)('0' + year / 10);
  result[16] = ' ';
  auto hour = time.hour;
  result[17] = cast(char)('0' + hour / 10);
  result[18] = cast(char)('0' + hour % 10);
  result[19] = ':';
  auto minute = time.minute;
  result[20] = cast(char)('0' + minute / 10);
  result[21] = cast(char)('0' + minute % 10);
  result[22] = ':';
  auto second = time.second;
  result[23] = cast(char)('0' + second / 10);
  result[24] = cast(char)('0' + second % 10);
  result[25..29] = " GMT";

  return cast(string) result;
}

unittest
{
  assert(formatDateTime(SysTime(DateTime(1998, 12, 25, 2, 15, 3), UTC()))
         == "Fri, 25 Dec 1998 02:15:03 GMT");
  assert(formatDateTime(SysTime(DateTime(2011, 5, 8, 17, 13, 59), UTC()))
         == "Sun, 08 May 2011 17:13:59 GMT");
}

enum Status : ushort {
  Continue                       = 100,
  SwitchingProtocols             = 101,
  OK                             = 200,
  Created                        = 201,
  Accepted                       = 202,
  NonAuthoritativeInformation    = 203,
  NoContent                      = 204,
  ResetContent                   = 205,
  PartialContent                 = 206,
  MultipleChoices                = 300,
  MovedPermanently               = 301,
  MovedTemporarily               = 302,
  SeeOther                       = 303,
  NotModified                    = 304,
  UseProxy                       = 305,
  TemporaryRedirect              = 307,
  BadRequest                     = 400,
  Unauthorized                   = 401,
  PaymentRequired                = 402,
  Forbidden                      = 403,
  NotFound                       = 404,
  MethodNotAllowed               = 405,
  NotAcceptable                  = 406,
  ProxyAuthenticationRequired    = 407,
  RequestTimeout                 = 408,
  Conflict                       = 409,
  Gone                           = 410,
  LengthRequired                 = 411,
  PreconditionFailed             = 412,
  RequestEntityTooLarge          = 413,
  RequestURITooLarge             = 414,
  UnsupportedMediaType           = 415,
  RequestedRangeNotSatisfiable   = 416,
  ExpectationFailed              = 417,
  InternalServerError            = 500,
  NotImplemented                 = 501,
  BadGateway                     = 502,
  ServiceUnavailable             = 503,
  GatewayTimeout                 = 504,
  HTTPVersionNotSupported        = 505
}

string[ushort] statusStrings;

static this()
{
  statusStrings =
    [
      100: "100 Continue\r\n",
      101: "101 Switching Protocols\r\n",
      200: "200 OK\r\n",
      201: "201 Created\r\n",
      202: "202 Accepted\r\n",
      203: "203 Non-Authoritative Information\r\n",
      204: "204 No Content\r\n",
      205: "205 Reset Content\r\n",
      206: "206 Partial Content\r\n",
      300: "300 Multiple Choices\r\n",
      301: "301 Moved Permanently\r\n",
      302: "302 Moved Temporarily\r\n",
      303: "303 See Other\r\n",
      304: "304 Not Modified\r\n",
      305: "305 Use Proxy\r\n",
      307: "307 Temporary Redirect\r\n",
      400: "400 Bad Request\r\n",
      401: "401 Unauthorized\r\n",
      402: "402 Payment Required\r\n",
      403: "403 Forbidden\r\n",
      404: "404 Not Found\r\n",
      405: "405 Method Not Allowed\r\n",
      406: "406 Not Acceptable\r\n",
      407: "407 Proxy Authentication Required\r\n",
      408: "408 Request Time-out\r\n",
      409: "409 Conflict\r\n",
      410: "410 Gone\r\n",
      411: "411 Length Required\r\n",
      412: "412 Precondition Failed\r\n",
      413: "413 Request Entity Too Large\r\n",
      414: "414 Request-URI Too Large\r\n",
      415: "415 Unsupported Media Type\r\n",
      416: "416 Requested Range Not Satisfiable\r\n",
      417: "417 Expectation Failed\r\n",
      500: "500 Internal Server Error\r\n",
      501: "501 Not Implemented\r\n",
      502: "502 Bad Gateway\r\n",
      503: "503 Service Unavailable\r\n",
      504: "504 Gateway Time-out\r\n",
      505: "505 HTTP Version Not Supported\r\n"
    ];
}
