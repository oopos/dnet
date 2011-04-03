import std.c.stdlib;
import std.stdio;

// Allocator designs by Andrei Alexandrescu.
// See http://www.nwcpp.org/old/Downloads/2008/memory-allocation.screen.pdf

struct Mallocator
{
  alias malloc allocate;
  alias free deallocate;
}

struct SizedAlloc(B)
{
  void* allocate(size_t s)
  { debug writeln("sized allocation");
    size_t* pS = cast(size_t*) b.allocate(s + size_t.sizeof);
    *pS = s;
    return pS + 1;
  }

  void deallocate(void* p)
  { debug writeln("sized deallocation");
    b.deallocate((cast(size_t*) p) - 1);
  }

  size_t allocatedSize(void* p)
  {
    return (cast(size_t*) p)[-1];
  }

  B b;
  alias b this;
}

struct ExactFreeList(size_t S, B, bool fixedSize = false)
{
  static if (!fixedSize)
  {
    void* allocate(size_t s)
    {
      if (s != S || !list)
        return b.allocate(s);
      void* r = list;
      list = list.next;
      return r;
    }
  }
  else
  {
    void* allocate()
    {
      if (!list)
        return b.allocate(S);
      void* r = list;
      list = list.next;
      return r;
    }
  }

  void deallocate(void* p)
  {
    static if (!fixedSize)
    {
      if (this.allocatedSize(p) != S)
        return b.deallocate(p);
    }
    List* pL = cast(List*) p;
    pL.next = list;
    list = pL;
  }

  B b;
  alias b this;

  private:
  struct List { List* next; }
  List* list;
}
