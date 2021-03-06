/*
    Title:      Signal handling
    Author:     David C.J. Matthews

    Copyright (c) 2000-8 David C.J. Matthews

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
#ifdef HAVE_CONFIG_H
#include "config.h"
#elif defined(_WIN32)
#include "winconfig.h"
#else
#error "No configuration file"
#endif

#ifdef HAVE_STDIO_H
#include <stdio.h>
#endif

#ifdef HAVE_SYS_TYPES_H
#include <sys/types.h>
#endif

#ifdef HAVE_SIGNAL_H
#include <signal.h>
#endif

#ifdef HAVE_ERRNO_H
#include <errno.h>
#endif

#ifdef HAVE_ASSERT_H
#include <assert.h>
#define ASSERT(x) assert(x)
#else
#define ASSERT(x) 0
#endif

#ifdef HAVE_STRING_H
#include <string.h>
#endif

#ifdef HAVE_IO_H
#include <io.h>
#endif

#ifdef HAVE_UNISTD_H
#include <unistd.h>
#endif

#ifdef HAVE_STDLIB_H
#include <stdlib.h> // For malloc
#endif

#if ((!defined(_WIN32) || defined(__CYGWIN__)) && defined(HAVE_SEMAPHORE_H))
// Don't include semaphore.h on Mingw.  It's provided but doesn't compile.
#include <semaphore.h>
#endif

#if ((!defined(_WIN32) || defined(__CYGWIN__)) && defined(HAVE_LIBPTHREAD) && defined(HAVE_PTHREAD_H) && defined(HAVE_SEMAPHORE_H))
// If we have the pthread library and header and we have semaphores we can use the pthread
// signalling mechanism.  But if this is a native Windows build we don't use semaphores or
// pthread even if they're provided.
#define USE_PTHREAD_SIGNALS 1
#endif

/*
Signal handling is complicated in a multi-threaded environment.
The pthread mutex and condition variables are not safe to use in a
signal handler so we need to use POSIX semaphores since sem_post is safe.
*/


#if (defined(HAVE_STACK_T) && defined(HAVE_SIGALTSTACK))
extern "C" {
// This is missing in older versions of Mac OS X 
int sigaltstack(const stack_t *, stack_t *);
}
#endif

#include "globals.h"
#include "arb.h"
#include "run_time.h"
#include "sighandler.h"
#include "processes.h"
#include "machine_dep.h"
#include "sys.h"
#include "save_vec.h"
#include "rts_module.h"
#include "gc.h" // For convertedWeak
#include "scanaddrs.h"
#include "locking.h"

#if (defined(_WIN32) && ! defined(__CYGWIN__))
#include "Console.h"
#endif

#define SAVE(x) taskData->saveVec.push(x)
#define SIZEOF(x) (sizeof(x)/sizeof(word))

#define DEFAULT_SIG     0
#define IGNORE_SIG      1
#define HANDLE_SIG      2 // This is only used in SignalRequest

static struct _sigData
{
    bool        nonMaskable; // True if this sig is used within the RTS.  Must not be ignored or replaced
    PolyWord    handler; // User-installed handler, TAGGED(DEFAULT_SIG) or TAGGED(IGNORE_SIG)
    int         signalCount;
} sigData[NSIG];

unsigned receivedSignalCount = 0; // Incremented each time we get a signal

// sigLock protects access to the signalCount values in sigData but
// not the "handler" field.
static PLock sigLock;

#ifdef USE_PTHREAD_SIGNALS
static PSemaphore *waitSema;
static int lastSignals[NSIG];
static bool terminate = false;
#endif


// This must not be called from an asynchronous signal handler.
static void signalArrived(int sig)
{
    sigLock.Lock();
    receivedSignalCount++;
    sigData[sig].signalCount++;
    sigLock.Unlock();
    // To avoid deadlock we must release sigLock first.
    processes->SignalArrived();
}

// Called whenever a signal handler is installed other than in this
// module.   Because modules are initialised in an unspecified order
// we may have already masked off this signal.
void markSignalInuse(int sig)
{
    sigData[sig].nonMaskable = true;
#ifdef USE_PTHREAD_SIGNALS
    // Enable this signal.
    sigset_t sigset;
    sigemptyset(&sigset);
    sigaddset(&sigset, sig);
    pthread_sigmask(SIG_UNBLOCK, &sigset, NULL);
#endif
}

/* Find the existing handler for this signal. */
static PolyWord findHandler(int sig)
{
    if ((unsigned)sig >= NSIG) // Check it's in range.
        return TAGGED(DEFAULT_SIG); /* Not there - default action. */
    else return sigData[sig].handler;
}

#if (defined(_WIN32) && ! defined(__CYGWIN__))
// This is called to simulate a SIGINT in Windows.
void RequestConsoleInterrupt(void)
{
    // The default action for SIGINT is to exit.
    if (findHandler(SIGINT) == TAGGED(DEFAULT_SIG))
        processes->Exit(2); // Exit with the signal value.
    else signalArrived(SIGINT);
}
#endif

#ifdef USE_PTHREAD_SIGNALS
// Request the main thread to change the blocking state of a signal.
class SignalRequest: public MainThreadRequest
{
public:
    SignalRequest(int s, int r): MainThreadRequest(MTP_SIGHANDLER), signl(s), state(r) {}

    virtual void Perform();
    int signl, state;
};

// Called whenever a signal is received.
static void handle_signal(SIG_HANDLER_ARGS(s, c))
{
    if (waitSema != 0)
    {
        lastSignals[s]++; // Assume this is atomic with respect to reading.
        // Wake the signal detection thread.
        waitSema->Signal();
    }
}

void SignalRequest::Perform()
{
    struct sigaction action;
    memset(&action, 0, sizeof(action));

    switch (state)
    {
    case DEFAULT_SIG:
        action.sa_handler = SIG_DFL;
        sigaction(signl, &action, 0);
        break;
    case IGNORE_SIG:
        action.sa_handler = SIG_IGN;
        sigaction(signl, &action, 0);
        break;
    case HANDLE_SIG:
        setSignalHandler(signl, handle_signal);
        break;
    }
}
#endif


/* CALL_IO2(Sig_dispatch_,IND) */
/* This function behaves fairly similarly to the Unix and Windows signal
   handler.  It takes a signal number and a handler which may be a function
   or may be 0 (default) or 1 (ignore) and returns the value corresponding
   to the previous handler. 
   I've used a general dispatch function here to allow for future expansion. */
Handle Sig_dispatch_c(TaskData *taskData, Handle args, Handle code)
{
    int c = get_C_int(taskData, DEREFWORDHANDLE(code));
    switch (c)
    {
    case 0: /* Set up signal handler. */
        {
            int sign;
            int action;
            Handle oldaction;
            {
                // Lock while we look at the signal vector but release
                // it before making a root request.
                PLocker locker(&sigLock);
                // We have to pass this to the main thread to 
                // set up the signal handler.
                sign = get_C_int(taskData, DEREFHANDLE(args)->Get(0));
                /* Decode the action if it is Ignore or Default. */
                if (IS_INT(DEREFHANDLE(args)->Get(1)))
                    action = (int)UNTAGGED(DEREFHANDLE(args)->Get(1));
                else action = HANDLE_SIG; /* Set the handler. */
                if (sign <= 0 || sign >= NSIG)
                    raise_syscall(taskData, "Invalid signal value", EINVAL);

                /* Get the old action before updating the vector. */
                oldaction = SAVE(findHandler(sign));
                // Now update it.
                sigData[sign].handler = DEREFWORDHANDLE(args)->Get(1);
            }

            // Request a change in the masking by the root thread.
            // This doesn't do anything in Windows so the only "signal"
            // we affect is SIGINT and that is handled by RequestConsoleInterrupt.
            if (! sigData[sign].nonMaskable)
            {
#ifdef USE_PTHREAD_SIGNALS
                SignalRequest request(sign, action);
                processes->MakeRootRequest(taskData, &request);
#endif
            }
            return oldaction;
        }

    case 1: // Called by the signal handler thread.  Blocks until a signal
            // is available.
        {
            while (true)
            {
                processes->ProcessAsynchRequests(taskData); // Check for kill.
                sigLock.Lock();
                // Any pending signals?
                for (int sig = 0; sig < NSIG; sig++)
                {
                    if (sigData[sig].signalCount > 0)
                    {
                        sigData[sig].signalCount--;
                        if (!IS_INT(findHandler(sig))) /* If it's not DEFAULT or IGNORE. */
                        {
                            // Create a pair of the handler and signal and pass
                            // them back to be run.
                            Handle pair = alloc_and_save(taskData, 2);
                            // Have to call findHandler again here because that
                            // allocation could have garbage collected.
                            DEREFHANDLE(pair)->Set(0, findHandler(sig));
                            DEREFHANDLE(pair)->Set(1, TAGGED(sig));
                            sigLock.Unlock();
                            return pair;
                        }
                    }
                }
                if (convertedWeak)
                {
                    // Last GC converted a weak SOME into NONE.  This isn't
                    // anything to do with signals but the signal thread can
                    // deal with this.
                    sigLock.Unlock();
                    convertedWeak = false;
                    return SAVE(TAGGED(0));
                }
                // No pending signal.  Wait until we're woken up.
                // This releases sigLock after acquiring schedLock.
                if (! processes->WaitForSignal(taskData, &sigLock))
                    raise_exception_string(taskData, EXC_Fail, "Only one thread may wait for signals");
            }
        }

    default:
        {
            char msg[100];
            sprintf(msg, "Unknown signal function: %d", c);
            raise_exception_string(taskData, EXC_Fail, msg);
            return 0;
        }
    }
}

// Set up per-thread signal data: basically signal stack.
// This is really only needed for profiling timer signals.
void initThreadSignals(TaskData *taskData)
{
#if (!(defined(_WIN32)||defined(MACOSX)))
    // On the i386, at least, we need to set up a signal stack for
    // each thread if it might receive a signal.  ML code checks for
    // stack overflow but a signal could result in C code being
    // executed on the ML stack.  The signal stack avoids this.
    // On some architectures the C stack pointer is left unused
    // when executing ML code so this isn't a problem.
    // In Linux each thread can receive a SIGVTALRM signal when
    // profiling.
    // This is currently disabled in Mac OS X.  In 10.4 and before
    // setting a signal stack in a thread seemed to set it for the
    // whole process and crash with an illegal instruction on the
    // second signal.  This isn't currently a problem since only the
    // main thread receives signals in Mac OS X.
#if (defined(SA_ONSTACK) && defined(HAVE_SIGALTSTACK))
    taskData->signalStack = malloc(SIGSTKSZ);
#ifdef HAVE_STACK_T
    stack_t ex_stack;
#else
    // This used to be used in FreeBSD and Mac OS X
    struct sigaltstack ex_stack;
#endif
    memset(&ex_stack, 0, sizeof(ex_stack));
    // Cast to char* because ss_sp is char* in FreeBSD.
    // Linux simply casts it back to void*.
    ex_stack.ss_sp    = (char*)taskData->signalStack;
    ex_stack.ss_size  = SIGSTKSZ;
    ex_stack.ss_flags = 0; /* not SS_DISABLE */
    int sigaltstack_result = sigaltstack(&ex_stack, NULL);
    ASSERT(sigaltstack_result == 0);
#endif
#endif /* not the PC */
#ifdef USE_PTHREAD_SIGNALS
    // Block all signals except those marked as in use by the RTS so
    // that they will only be picked up by the signal detection thread.
    // Since the signal mask is inherited we really don't need to do
    // this for every thread, just the initial one.
    sigset_t sigset;
    sigfillset(&sigset);
    for (int i = 0; i < NSIG; i++)
    {
        if (sigData[i].nonMaskable)
            sigdelset(&sigset, i);
    }
    pthread_sigmask(SIG_SETMASK, &sigset, NULL);
#endif
}


/* General purpose function to set up a signal handler. */
#if (!defined(_WIN32) || defined(__CYGWIN__))

bool setSignalHandler(int sig, signal_handler_type func)
{
    struct sigaction sigcatch;
    memset(&sigcatch, 0, sizeof(sigcatch));
    sigcatch.sa_sigaction = func;

    /*
    Both Linux and FreeBSD now use SA_SIGINFO in a similar way.  If SA_SIGINFO is set the
    handler is supposed to be in sa_sigaction rather than sa_handler (actually this is a union
    so they're in the same place).  
    */

    init_asyncmask(&sigcatch.sa_mask);
    sigcatch.sa_flags = 0;
#if defined(SA_ONSTACK) && defined(HAVE_SIGALTSTACK)
    sigcatch.sa_flags |= SA_ONSTACK;
#endif
#ifdef SA_RESTART
    sigcatch.sa_flags |= SA_RESTART;
#endif
#ifdef SA_SIGINFO
    sigcatch.sa_flags |= SA_SIGINFO;
#endif
#ifdef SV_SAVE_REGS
    sigcatch.sa_flags |= SV_SAVE_REGS;
#endif

    return sigaction(sig, &sigcatch,NULL) >= 0;
}

// Signals to mask off when handling a signal.  The signal being handled
// is always masked off.  This really only applied when emulation traps
// and requests to GC involved signals.  That no longer applies except
// on the Sparc.
void init_asyncmask(sigset_t *mask)
{
    /* disable asynchronous interrupts while servicing interrupt */
    sigemptyset(mask);
    sigaddset(mask,SIGVTALRM);
    sigaddset(mask,SIGINT);
    sigaddset(mask,SIGUSR2);
    sigaddset(mask,SIGWINCH);

    // This next used to be needed when emulation traps resulted in
    // signals.  This no longer applies except on the Sparc.
#ifdef SPARC
    sigaddset(mask,SIGILL);
    sigaddset(mask,SIGFPE);
    /* Mask off SIGSEGV.  This is definitely needed when we are
       installing a handler for SIGINT under Linux and may also
       be needed in other cases as well e.g. SIGVTALRM. Without
       it typing control-C to a program which is taking lots
       of emulation traps can cause a crash because the signals
       are delivered in the "wrong" order and the pc value given
       to catchSEGV can point at the handler for SIGINT.
       DCJM 7/2/01. */
    sigaddset(mask,SIGSEGV);
    /* And, just to be sure, include SIGBUS.  DCJM 22/5/02. */
    sigaddset(mask,SIGBUS);
#endif
}

#endif

class SigHandler: public RtsModule
{
public:
    virtual void Init(void);
    virtual void Stop(void);
    virtual void GarbageCollect(ScanAddress * /*process*/);

#ifdef USE_PTHREAD_SIGNALS
    SigHandler() { threadRunning = false; }
    pthread_t detectionThreadId;
    bool      threadRunning;
#endif
};

// Declare this.  It will be automatically added to the table.
static SigHandler sighandlerModule;

#ifdef USE_PTHREAD_SIGNALS
// This thread is really only to convert between POSIX semaphores and
// pthread condition variables.  It waits for a semphore to be released by the
// signal handler running on the main thread and then wakes up the ML handler
// thread.  The ML thread must not wait directly on a POSIX semaphore because it
// may also be woken by other events, particularly a kill request when the program
// exits.
static void *SignalDetectionThread(void *)
{
    // Block all signals so they will be delivered to the main thread.
    sigset_t active_signals;    
    sigfillset(&active_signals);
    pthread_sigmask(SIG_SETMASK, &active_signals, NULL);
    int readSignals[NSIG] = {0};

    while (true)
    {
        if (waitSema == 0)
            return 0;
        // Wait until we are woken up by an arriving signal.
        // waitSema will be incremented for each signal so we should
        // not block until we have processed them all.
        if (! waitSema->Wait() || terminate) return 0;

        for (int j = 1; j < NSIG; j++)
        {
            if (readSignals[j] < lastSignals[j])
            {
                readSignals[j]++;
                signalArrived(j);
            }
        }
    }
}
#endif

void SigHandler::Init(void)
{
    // Mark certain signals as non-maskable since they really
    // indicate a fatal error.
#ifdef SIGSEGV
    sigData[SIGSEGV].nonMaskable = true;
#endif
#ifdef SIGBUS
    sigData[SIGBUS].nonMaskable = true;
#endif
#ifdef SIGILL
    sigData[SIGILL].nonMaskable = true;
#endif
#ifdef USE_PTHREAD_SIGNALS
    static PSemaphore waitSemaphore;
    // Initialise the "wait" semaphore so that it blocks immediately.
    if (! waitSemaphore.Init(0, NSIG)) return;
    waitSema = &waitSemaphore;
    // Create a new thread to handle signals synchronously.
    // for it to finish.
    pthread_attr_t attrs;
    pthread_attr_init(&attrs);
#ifdef PTHREAD_STACK_MIN
#if (PTHREAD_STACK_MIN < 4096)
    pthread_attr_setstacksize(&attrs, 4096); // But not too small: FreeBSD makes it 2k
#else
    pthread_attr_setstacksize(&attrs, PTHREAD_STACK_MIN); // Only small stack.
#endif
#endif
    threadRunning = pthread_create(&detectionThreadId, &attrs, SignalDetectionThread, 0) == 0;
    pthread_attr_destroy(&attrs);
#endif
}

// Wait for the signal thread to finish before the semaphore is deleted in the
// final clean-up.  Failing to do this causes a hang in Mac OS X.
void SigHandler::Stop(void)
{
#ifdef USE_PTHREAD_SIGNALS
    terminate = true;
    waitSema->Signal();
    pthread_join(detectionThreadId, NULL);
#endif
}

void SigHandler::GarbageCollect(ScanAddress *process)
{
    for (unsigned i = 0; i < NSIG; i++)
    {
        if (sigData[i].handler != PolyWord::FromUnsigned(0))
            process->ScanRuntimeWord(&sigData[i].handler);
    }
}
