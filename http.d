import std.stdio, std.exception, std.typecons, std.conv, std.c.stdlib,
       core.thread, core.sys.posix.arpa.inet, core.sys.posix.signal,
       core.sys.posix.poll, core.stdc.errno;
import socket, socketstream, httpparser, eventloop, util;
public import httpparser: HttpRequest, HttpResponse;

alias void delegate(ref HttpRequest, HttpResponder) HttpRequestHandler;
// Scope correct?
enum PAGESIZE = 4096;

static this()
{
  sigaction_t sa;
  sa.sa_handler = SIG_IGN;
  sigaction(SIGPIPE, &sa, null);
}

struct HttpServer
{
  enum BUFFERSIZE = PAGESIZE;
  
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
  HttpRequestHandler onRequest;
  
  private:
  void accept()
  {
    while(!_stop)
    {
      auto newSock = _socket.accept();
      debug writeln(newSock.fd, " accept()ed");
      if (_connections < maxConnections)
      {
        (new Fiber(scopeDelegate(
        {
          auto fibSock = newSock; // We move newSock right away, so scopeDelegate is safe
          ++_connections;
          debug writeln("connections = ", _connections);
          try
          {
            ubyte[BUFFERSIZE] buffer = void;
            auto ss = SocketStream!(AsyncSocket*)(&fibSock, buffer);
            parseHttpRequest(&ss,
              (ref HttpRequest request)
              {
                onRequest(request, HttpResponder(&fibSock));
              });
          }
          catch (Exception e) 
          {
            writeln("Error in fd ", fibSock.fd, ": ", e.msg);
          }
          debug writeln(fibSock.fd, " close()d");
          --_connections;
          fibSock.close();
        }
        ), BUFFERSIZE + PAGESIZE*3)).call();
      }
      else
        newSock.close();
    }
    _stop = false;
  }
  
  AsyncSocket _socket;
  uint _connections;
  bool _stop;
}

struct HttpResponder
{
  mixin HttpSender;
  AsyncSocket* socket;
  alias socket _socket;
  HttpRequest request;
  HttpContentEvent onContent;
  
  /*this(AsyncSocket* socket, HttpRequest request)
  {
    this.socket = socket;
    this.request = request;
  }*/
  
  void respond(uint status, string[string] headers)
  {
    sendHeader("HTTP/1.1 " ~ statusStrings[status], headers);
  }
}

alias BasicHttpClient!Socket HttpClient;
alias BasicHttpClient!AsyncSocket HttpClientAsync;

struct BasicHttpClient(SocketT, size_t BUFFERSIZE = PAGESIZE)
{
  mixin HttpSender;

  this(uint ip, ushort port)
  {
    setAddress(ip, port);
  }

  ~this()
  {
    close();
  }

  void setAddress(uint ip, ushort port)
  {
    _sin = sockaddr_in(AF_INET, htons(port), in_addr(htonl(ip)));
  }

  void request(string method, string uri, string[string] headers)
  {
    ensureConnection();
    sendHeader(method~' '~uri~" HTTP/1.1\r\n", headers);
  }

  auto autoRequest(string method, string uri, string[string] headers,
    string content = null, size_t maxResponseContentLength = 200*1024)
  {
    HttpResponse savedResponse;
    string savedContent;
    if (content.length)
    {
      headers["content-length"] = to!string(content.length);
      request(method, uri, headers);
      sendContent(content);
    }
    else
      request(method, uri, headers);

    //debug stderr.writeln("request sent");
    
    getResponse((ref HttpResponse response)
      {
        savedResponse = response;
        response.onContent =
          (const(char)[] chunk)
          {
            if (savedContent.length + chunk.length > maxResponseContentLength)
            {
              response.onContent = null; // Stop appending chunks
              return;
            }
            savedContent ~= chunk; 
          };
      });
    return Tuple!(HttpResponse, "response", string, "content")
      (savedResponse, savedContent);
  }
  
  void getResponse(scope HttpResponseHandler onResponse)
  {
    parseHttpResponse(&_ss, onResponse);
  }

  void close()
  {
    if(_socket.isOpen)
      _socket.close();
  }
  
  private:  
  void ensureConnection()
  {
    /*version(linux)
      enum POLLRDHUP = 0x2000;
    auto pfd = pollfd(_socket.fd, cast(short) 0xffff); // all events
    syscallEnforce(poll(&pfd, 1, 0), "poll");*/
    
    if (!_socket.isOpen)
    {
      createAndConnect();
      _ss = SocketStreamType(&_socket, _buffer);
    }
    else
    {
      version(linux)
        enum MSG_DONTWAIT = 0x40;
      
      ubyte buf;
      recvAgain:
      auto ret = recv(_socket.fd, &buf, 1, MSG_DONTWAIT);
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
        debug writeln("Disconnected. Reconnecting.");
        _socket.close();
        createAndConnect();
      }
      else if (ret == 1)
      {
        _socket.close();
        throw new Exception("HttpClient: Unexpected data from server");
      }
    }
  }

  void createAndConnect()
  {
    _socket.create(AF_INET, SOCK_STREAM, 0);
    scope(failure) _socket.close();
    _socket.connect(_sin);
  }
  
  sockaddr_in _sin;
  SocketT _socket;
  alias SocketStream!(SocketT*) SocketStreamType;
  SocketStreamType _ss;
  ubyte[BUFFERSIZE] _buffer;
}

private mixin template HttpSender()
{
  void sendHeader(string firstline, string[string] headers)
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
  
  void send(in char[][] chunks...)
  {
    _socket.sendAll(0, cast(const ubyte[][]) chunks);
  }
  
  void sendCorked(in char[][] chunks...)
  {
    _socket.sendAll(MSG_MORE, cast(const ubyte[][]) chunks);
  }
}

string[uint] statusStrings;

static this()
{
  statusStrings = // This list is taken from node.js
    [
      100: "100 Continue\r\n",
      101: "101 Switching Protocols\r\n",
      102: "102 Processing\r\n",                 // RFC 2518, obsoleted by RFC 4918
      200: "200 OK\r\n",
      201: "201 Created\r\n",
      202: "202 Accepted\r\n",
      203: "203 Non-Authoritative Information\r\n",
      204: "204 No Content\r\n",
      205: "205 Reset Content\r\n",
      206: "206 Partial Content\r\n",
      207: "207 Multi-Status\r\n",               // RFC 4918
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
      418: "418 I'm a teapot\r\n",               // RFC 2324
      422: "422 Unprocessable Entity\r\n",       // RFC 4918
      423: "423 Locked\r\n",                     // RFC 4918
      424: "424 Failed Dependency\r\n",          // RFC 4918
      425: "425 Unordered Collection\r\n",       // RFC 4918
      426: "426 Upgrade Required\r\n",           // RFC 2817
      500: "500 Internal Server Error\r\n",
      501: "501 Not Implemented\r\n",
      502: "502 Bad Gateway\r\n",
      503: "503 Service Unavailable\r\n",
      504: "504 Gateway Time-out\r\n",
      505: "505 HTTP Version Not Supported\r\n",
      506: "506 Variant Also Negotiates\r\n",    // RFC 2295
      507: "507 Insufficient Storage\r\n",       // RFC 4918
      509: "509 Bandwidth Limit Exceeded\r\n",
      510: "510 Not Extended\r\n"                // RFC 2774
    ];
}

