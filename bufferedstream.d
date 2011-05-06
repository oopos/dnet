import std.exception;

void popAndNotEmpty(BufStream)(BufStream stream)
{
    stream.popFront();
    enforce(!stream.empty, "stream ended unexpectedly");
}

void ensureLength(BufStream)(BufStream stream, size_t n)
{
  if (n > stream.front.length)
  {
    if (!stream.front.length)
    {
      popAndNotEmpty(stream);
      if (n <= stream.front.length)
        return;
    }

    size_t toRead = n - stream.front.length;
    enforce(stream.appendToFront(toRead) >= toRead, "stream ended unexpectedly");
  }
}

auto frontThenShift(BufStream)(BufStream stream)
{
  if (!stream.front.length)
    popAndNotEmpty(stream);
  auto e = stream.front[0];
  stream.shiftFront(1);
  return e;
}
 
void shiftStream(BufStream)(BufStream stream, size_t n)
{
  while(n > stream.front.length)
  {
    n -= stream.front.length;
    popAndNotEmpty(stream);
  }
  stream.shiftFront(n);
}