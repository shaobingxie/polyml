/*
    Title:      Mutex and Condition Variable library.

    Copyright (c) 2007, 2012 David C. J. Matthews

    This library is free software; you can redistribute it and/or
    modify it under the terms of the GNU Lesser General Public
    License as published by the Free Software Foundation; either
    version 2.1 of the License, or (at your option) any later version.
    
    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    Lesser General Public License for more details.
    
    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

*/

#ifndef LOCKING_H_DEFINED
#define LOCKING_H_DEFINED

#ifdef HAVE_CONFIG_H
#include "config.h"
#elif defined(_WIN32)
#include "winconfig.h"
#else
#error "No configuration file"
#endif

#ifdef HAVE_WINDOWS_H
#include <windows.h>
#endif

#if ((!defined(_WIN32) || defined(__CYGWIN__)) && defined(HAVE_SEMAPHORE_H))
// Don't include semaphore.h on Mingw.  It's provided but doesn't compile.
#include <semaphore.h>
#endif

#if ((!defined(_WIN32) || defined(__CYGWIN__)) && defined(HAVE_PTHREAD_H))
// Don't include pthread if this is native Windows and not Cygwin
#include <pthread.h>
#endif

// Simple Mutex.
class PLock {
public:
    PLock(const char *n = 0);
    ~PLock();
    void Lock(void); // Lock the mutex
    void Unlock(void); // Unlock the mutex
    bool Trylock(void); // Try to lock the mutex - returns true if succeeded

private:
#if ((!defined(_WIN32) || defined(__CYGWIN__)) && defined(HAVE_PTHREAD_H))
    pthread_mutex_t lock;
#elif defined(HAVE_WINDOWS_H)
    CRITICAL_SECTION lock;
#endif
    // Debugging info.
    const char *lockName;
    unsigned lockCount;

    friend class PCondVar;
};

// Lock a mutex and automatically unlock it in the destructor.
// This can be used in a function to lock a mutex and unlock it
// when the function either returns normally or raises an exception.
class PLocker {
public:
    PLocker(PLock *lock): m_lock(lock) { m_lock->Lock(); }
    ~PLocker() { m_lock->Unlock(); }
private:
    PLock *m_lock;
};

// Simple condition variable.  N.B.  The Windows code does not
// support multiple threads blocking on this condition variable.
class PCondVar {
public:
    PCondVar();
    ~PCondVar();
    void Wait(PLock *pLock); // Wait indefinitely.  Drops the lock and reaquires it.
    // Wait for a signal or until the time.  The argument is an absolute time
    // represented as a struct timespec in Unix and a FILETIME in Windows.
#if (defined(_WIN32) && ! defined(__CYGWIN__))
    void WaitUntil(PLock *pLock, const FILETIME *timeArg);
#else
    void WaitUntil(PLock *pLock, const timespec *timeArg);
#endif
    // Wait for a time.  This is used internally in the RTS.
    bool WaitFor(PLock *pLock, unsigned milliseconds);
    // N.B.  Signal MUST be called only with the lock held.
    void Signal(void); // Wake up the waiting thread.
private:
#if ((!defined(_WIN32) || defined(__CYGWIN__)) && defined(HAVE_PTHREAD_H))
    pthread_cond_t cond;
#elif defined(HAVE_WINDOWS_H)
    CONDITION_VARIABLE cond;
#endif
};

// Semaphore.  Wrapper for Posix semaphore or Windows semaphore.
class PSemaphore {
public:
    PSemaphore();
    ~PSemaphore();
    bool Init(unsigned init, unsigned max);
    bool Wait(void);
    void Signal(void);
private:
#if ((!defined(_WIN32) || defined(__CYGWIN__)) && defined(HAVE_SEMAPHORE_H))
    sem_t localSema, *sema;
    bool isLocal;
#elif defined(HAVE_WINDOWS_H)
    HANDLE sema;
#endif
};

#endif
