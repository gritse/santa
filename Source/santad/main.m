/// Copyright 2015 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#include "SNTLogging.h"

#include <pthread/pthread.h>
#include <sys/resource.h>

#import "SNTApplication.h"

///  Converts a timeval struct to double, converting the microseconds value to seconds.
static inline double timeval_to_double(struct timeval tv) {
  return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

///  The watchdog thread function, used to monitor santad CPU/RAM usage and print a warning
///  if it goes over certain thresholds.
void *watchdogThreadFunction(__unused void *idata) {
  pthread_setname_np("com.google.santa.watchdog");

  // Number of seconds to wait between checks.
  const int timeInterval = 60;

  // Amount of CPU usage to trigger warning, as a percentage averaged over timeInterval
  // santad's usual CPU usage is 0-3% but can occasionally spike if lots of processes start at once.
  const int cpuWarnThreshold = 20.0;

  // Amount of RAM usage to trigger warning, in MB.
  // santad's usual RAM usage is between 5-50MB but can spike if lots of processes start at once.
  const int memWarnThreshold = 250;

  double prevTotalTime = 0.0;
  double prevRamUseMB = 0.0;
  struct rusage usage;
  struct mach_task_basic_info taskInfo;
  mach_msg_type_number_t taskInfoCount = MACH_TASK_BASIC_INFO_COUNT;

  while(true) {
    @autoreleasepool {
      sleep(timeInterval);

      // CPU
      getrusage(RUSAGE_SELF, &usage);
      double totalTime = timeval_to_double(usage.ru_utime) + timeval_to_double(usage.ru_stime);
      double percentage = (((totalTime - prevTotalTime) / (double)timeInterval) * 100.0);
      prevTotalTime = totalTime;

      if (percentage > cpuWarnThreshold) {
        LOGW(@"Watchdog: potentially high CPU use, ~%.2f%% over last %d seconds.",
             percentage, timeInterval);
      }

      // RAM
      if (KERN_SUCCESS == task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                                    (task_info_t)&taskInfo, &taskInfoCount)) {
        double ramUseMB = (double) taskInfo.resident_size / 1024 / 1024;
        if (ramUseMB > memWarnThreshold && ramUseMB > prevRamUseMB) {
          LOGW(@"Watchdog: potentially high RAM use, RSS is %.2fMB.", ramUseMB);
        }
        prevRamUseMB = ramUseMB;
      }
    }
  }
  return NULL;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    // Do not buffer stdout
    setbuf(stdout, NULL);

    // Do not wait on child processes
    signal(SIGCHLD, SIG_IGN);

    NSDictionary *infoDict = [[NSBundle mainBundle] infoDictionary];

    if ([[[NSProcessInfo processInfo] arguments] containsObject:@"-v"]) {
      printf("%s\n", [infoDict[@"CFBundleVersion"] UTF8String]);
      return 0;
    }

    LOGI(@"Started, version %@", infoDict[@"CFBundleVersion"]);

    SNTApplication *s = [[SNTApplication alloc] init];
    [s performSelectorInBackground:@selector(run) withObject:nil];

    // Create watchdog thread
    pthread_t watchdogThread;
    pthread_create(&watchdogThread, NULL, watchdogThreadFunction, NULL);

    [[NSRunLoop mainRunLoop] run];
  }
}
