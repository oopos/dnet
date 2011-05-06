import std.stdio, std.conv, std.random, std.array, std.exception, std.algorithm, core.thread, core.memory;
import std.string: hexdigits;
import http, eventloop, util;

void main()
{
  auto server = HttpServer(8080);
  auto couchDb = HttpClient(0x7f000001, 5984);
  server.maxConnections = 500;
  server.onRequest = scopeDelegate(
    (HttpRequest request, ref HttpServer.Conversation conversation)
    {
      if (request.uri != "/")
      {
        conversation.respond(404, ["Content-Length": "0"]);
        return;
      }

      couchDb.request(
        "GET",
        "/example/_design/mydesign/_view/myview",
        ["Host": "localhost"]);
       HttpResponse couchResponse = couchDb.getResponse();
       enforce(couchResponse.status == 200);

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
      
      pre
      {
        font-size: 15px;
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
    <pre>", joinContent(couchDb.receivedContent),
    "</pre>
    <p>POST data:</p>
    <pre>", joinContent(conversation.receivedContent),
    `</pre>
    <form action="/" method="POST">
      <input type="text" name="text" />
      <input type="submit" value="Submit" />
    </form>
  </body>
</html>
`);
      conversation.respond(200,
        ["Content-Type": "text/html; charset=utf-8",
         "Transfer-Encoding": "chunked"]); // Chunked for kicks
      conversation.sendChunk(content);
      conversation.endChunked();
    });
    server.start();
    eventLoop.run();
}
