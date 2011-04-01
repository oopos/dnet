/* Copyright (C) 2002,2003,2004,2005,2006,2007,2008 Free Software Foundation, Inc.
   This file is part of the GNU C Library.

   The GNU C Library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2.1 of the License, or (at your option) any later version.

   The GNU C Library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with the GNU C Library; if not, write to the Free
   Software Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
   02111-1307 USA.  */


import core.sys.posix.signal : sigset_t;

/* Flags to be passed to epoll_create2.  */
enum
{
  EPOLL_CLOEXEC = 02000000,
  EPOLL_NONBLOCK = 04000
}


enum // EPOLL_EVENTS
{
  EPOLLIN = 0x001,
  EPOLLPRI = 0x002,
  EPOLLOUT = 0x004,
  EPOLLRDNORM = 0x040,
  EPOLLRDBAND = 0x080,
  EPOLLWRNORM = 0x100,
  EPOLLWRBAND = 0x200,
  EPOLLMSG = 0x400,
  EPOLLERR = 0x008,
  EPOLLHUP = 0x010,
  EPOLLRDHUP = 0x2000,
  EPOLLONESHOT = (1 << 30),
  EPOLLET = (1 << 31)
}


/* Valid opcodes ( "op" parameter ) to issue to epoll_ctl().  */
enum EPOLL_CTL_ADD = 1;	/* Add a file decriptor to the interface.  */
enum EPOLL_CTL_DEL = 2;	/* Remove a file decriptor from the interface.  */
enum EPOLL_CTL_MOD = 3;	/* Change file decriptor epoll_event structure.  */


union epoll_data
{
  void* ptr;
  int fd;
  uint u32;
  ulong u64;
}

align(1) struct epoll_event
{
  uint events;	/* Epoll events */
  epoll_data data;	/* User data variable */
}


extern(C)
{
/* Creates an epoll instance.  Returns an fd for the new instance.
   The "size" parameter is a hint specifying the number of file
   descriptors to be associated with the new instance.  The fd
   returned by epoll_create() should be closed with close().  */
  int epoll_create(int size);

/* Same as epoll_create but with an FLAGS parameter.  The unused SIZE
   parameter has been dropped.  */
  int epoll_create1(int flags);


/* Manipulate an epoll instance "epfd". Returns 0 in case of success,
   -1 in case of error ( the "errno" variable will contain the
   specific error code ) The "op" parameter is one of the EPOLL_CTL_*
   constants defined above. The "fd" parameter is the target of the
   operation. The "event" parameter describes which events the caller
   is interested in and any associated user data.  */
  int epoll_ctl(int epfd, int op, int fd,
	    epoll_event* event);


/* Wait for events on an epoll instance "epfd". Returns the number of
   triggered events returned in "events" buffer. Or -1 in case of
   error with the "errno" variable set to the specific error code. The
   "events" parameter is a buffer that will contain triggered
   events. The "maxevents" is the maximum number of events to be
   returned ( usually size of "events" ). The "timeout" parameter
   specifies the maximum wait time in milliseconds (-1 == infinite).

   This function is a cancellation point and therefore not marked with
   __THROW.  */
  int epoll_wait (int epfd, epoll_event* events,
      int maxevents, int timeout);


/* Same as epoll_wait, but the thread's signal mask is temporarily
   and atomically replaced with the one provided as parameter.

   This function is a cancellation point and therefore not marked with
   __THROW.  */
  int epoll_pwait(int epfd, epoll_event* events,
	    int maxevents, int timeout,
	    const sigset_t *ss);
}
