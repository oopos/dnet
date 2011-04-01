import std.stdio, std.conv, std.random, core.thread, core.memory;
import std.string: hexdigits;
import http, eventloop, util;

void main()
{
  auto server = HttpServer(8080);
  server.maxConnections = 500;
  server.onRequest =
    scopeDelegate((ref HttpRequest request, HttpResponder responder)
    {
      if (request.uri != "/")
      {
        responder.respond(404, ["Content-Length": "0"]);
        return;
      }

      auto couchDb = HttpClientAsync(0x7f000001, 5984);
      auto couchResponse = couchDb.autoRequest(
        "GET",
        "/example/_design/mydesign/_view/myview",
        ["Host": "localhost"]);
    
       string content = text(
"<!doctype html>
<html>
  <head>
    <title>Hi!</title>
    <style>
      body {
        background-color: #D1EAEF;
        font: 20px Trebuchet MS;
        width: 800px;
        margin: auto;
      }
      
      h1 {
        color: #",
          hexdigits[uniform(0, 16)],
          hexdigits[uniform(0, 16)],
          hexdigits[uniform(0, 16)], ";
        font-size: 4em;
      }
      
      h2 {
        font-size: 2em;
      }
      
      blockquote
      {
        font: 15px Monospace;
        background-color: #222;
        color: #fff;
        padding: 10px;
      }
    </style>
  </head>
  <body>
    <h1>Hi!</h1>
    <p>Here is a random number: ", uniform(0, 10), "</p>
    <p>And some data from the database:</p>
    <blockquote>
    ", couchResponse.content, "
    </blockquote>
  </body>
</html>
");
      responder.respond(200,
        ["Content-Type": "text/html; charset=utf-8",
         "Transfer-Encoding": "chunked"]); // Chunked for kicks
      responder.sendChunk(content);
      responder.endChunked();
    });
    server.start();
    eventLoop.run();
}
