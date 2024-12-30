//
//  main.m
//  objfind
//
//  Created by Ethan Arbuckle on 12/29/24.
//

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import "ansi.h"
#import "class_clusters.h"

#define VERSION "1.0.0"

typedef struct _VMUObjectGraphNode {
    uint64_t address;
    uint64_t length : 60;
    uint64_t nodeType : 4;
    __unsafe_unretained id classInfo;
} VMUObjectGraphNode;

typedef struct {
    char process_name[256];
    pid_t pid;
    uint64_t object_count;
    uint64_t total_size;
    NSMutableArray *objects;
} ProcessStats;

typedef NS_ENUM(uint32_t, VMUScanMask) {
    VMUScanMaskNone               = 0,
    VMUScanMaskConservative       = 1,
    VMUScanMaskStrongRef         = 2,
    VMUScanMaskUnownedRef        = 3,
    VMUScanMaskWeakRef           = 4,
    VMUScanMaskSwiftWeakRef      = 5,
    VMUScanMaskUnsafeUnretained  = 8,
    VMUScanMaskMaxValue          = VMUScanMaskUnsafeUnretained,
};

static bool should_scan_process(const char *process_name) {
    const char *skip_prefixes[] = {
        "launchd",
        "com.apple.",
        "ssh",
        "zsh",
        "ReportCrash",
        "coresymbolicat",
        "microstackshot",
        "symptomsd",
        "tailspind",
        NULL
    };
    
    for (const char **prefix = skip_prefixes; *prefix; prefix++) {
        if (strstr(process_name, *prefix) != NULL) {
            return false;
        }
    }
    return true;
}

static id create_memory_scanner(task_t task) {
    Class task_class = objc_getClass("VMUTask");
    SEL init_task_sel = sel_registerName("initWithTask:");
    id vmu_task = ((id(*)(id, SEL, task_t))objc_msgSend)([task_class alloc], init_task_sel, task);
    if (!vmu_task) {
        return nil;
    }
    
    Class scanner_class = objc_getClass("VMUTaskMemoryScanner");
    SEL init_scanner_sel = sel_registerName("initWithVMUTask:options:");
    uint32_t VMUFlagsForAllVMRegionStatistics = 2076;
    id scanner = ((id(*)(id, SEL, id, uint64_t))objc_msgSend)([scanner_class alloc], init_scanner_sel, vmu_task, VMUFlagsForAllVMRegionStatistics);
    [vmu_task release];
    
    if (!scanner) {
        return nil;
    }
    
    // (val & 0xFFFFFFFE ) != 2
    // readOnlyContent: 2
    // fullContent: 3
    ((void(*)(id, SEL, uint32_t))objc_msgSend)(scanner, sel_registerName("setObjectContentLevel:"), 3);
    ((void(*)(id, SEL, uint32_t))objc_msgSend)(scanner, sel_registerName("setScanningMask:"), VMUScanMaskConservative);
    ((void(*)(id, SEL, BOOL))objc_msgSend)(scanner, sel_registerName("setShowRawClassNames:"), YES);
    ((void(*)(id, SEL, BOOL))objc_msgSend)(scanner, sel_registerName("setAbandonedMarkingEnabled:"), NO);

    NSError *error = nil;
    ((void (*)(id, SEL, id *))objc_msgSend)(scanner, sel_registerName("addAllNodesFromTaskWithError:"), &error);
    if (error) {
        printf("%sError adding nodes: %s%s\n", ANSI_RED, error.localizedDescription.UTF8String, ANSI_RESET);
        [error release];
        [scanner release];
        return nil;
    }
    
    return scanner;
}

static void print_process_header(ProcessStats *stats) {
    printf("\n%s%s", ANSI_WHITE, BOX_TOP_LEFT);
    for (int i = 0; i < 80; i++) {
        printf(BOX_HORIZ);
    }
    printf("%s\n", ANSI_RESET);
    
    printf("%s%s %sProcess:%s %s%s%s (%sPID:%s %s%d%s)\n",
           ANSI_WHITE, BOX_VERT,
           ANSI_BOLD, ANSI_RESET,
           ANSI_GREEN, stats->process_name, ANSI_RESET,
           ANSI_WHITE, ANSI_RESET,
           ANSI_YELLOW, stats->pid, ANSI_RESET);

    printf("%s%s Found %s%llu%s objects (%s%llu%s bytes total)\n",
           ANSI_WHITE, BOX_VERT,
           ANSI_BLUE, stats->object_count, ANSI_RESET,
           ANSI_MAGENTA, stats->total_size, ANSI_RESET);
    
    printf("%s%s", ANSI_WHITE, BOX_TEE_RIGHT);
    for (int i = 0; i < 80; i++) {
        printf(BOX_HORIZ);
    }
    printf("%s\n", ANSI_RESET);
}

static void print_object_details(NSString *className, VMUObjectGraphNode nodeInfo, id classInfo, id scanner) {

    printf("%s%s%s %s%s%s @ %s0x%llx%s (%s%llu%s bytes)  ",
             ANSI_WHITE, BOX_TEE_RIGHT, BOX_CONNECT,
             ANSI_BOLD, className.UTF8String, ANSI_RESET,
             ANSI_YELLOW, nodeInfo.address, ANSI_RESET,
             ANSI_MAGENTA, nodeInfo.length, ANSI_RESET);
    
    printf("%s\n", ANSI_RESET);
    
    __weak id weak_scanner = scanner;
    ((void (*)(id, SEL, id))objc_msgSend)(classInfo, sel_registerName("enumerateAllFieldsWithBlock:"), ^(id field, NSUInteger index, BOOL *stop) {
        NSString *type_desc = ((NSString *(*)(id, SEL))objc_msgSend)(field, sel_registerName("typedDescription"));
        NSString *value_desc = ((NSString *(*)(id, SEL, id, id))objc_msgSend)(field, sel_registerName("descriptionOfFieldValueInObjectMemory:scanner:"), nodeInfo.classInfo, weak_scanner);
        printf("%s%s    %s%s %s%s%s: %s%s%s\n",
               ANSI_WHITE, BOX_VERT,
               ANSI_GRAY, BOX_TEE_RIGHT BOX_CONNECT,
               ANSI_YELLOW, type_desc.UTF8String, ANSI_RESET,
               ANSI_CYAN, value_desc.UTF8String, ANSI_RESET);
    });
}

static void scan_process_for_class_instances(const char *process_name, pid_t pid, const char *target_class, bool exact_match) {
    task_t task;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) {
        printf("%sFailed to get task for PID %d%s\n", ANSI_RED, pid, ANSI_RESET);
        return;
    }
    
    id scanner = create_memory_scanner(task);
    if (!scanner) {
        mach_port_deallocate(mach_task_self(), task);
        return;
    }
    
    __block ProcessStats stats = {0};
    strncpy(stats.process_name, process_name, sizeof(stats.process_name) - 1);
    stats.pid = pid;
    stats.objects = [[NSMutableArray alloc] init];
    
    const ClassCluster *cluster = find_cluster_for_class(target_class);
    
    ((void (*)(id, SEL, id))objc_msgSend)(scanner, sel_registerName("enumerateObjectsWithBlock:"), ^(uint32_t nodeName, VMUObjectGraphNode nodeInfo, BOOL *stop) {
        id classInfo = nodeInfo.classInfo;
        if (!classInfo) {
            return;
        }
        
        NSString *className = ((NSString *(*)(id, SEL))objc_msgSend)(classInfo, sel_registerName("className"));
        bool match = (exact_match) ? strcmp(className.UTF8String, target_class) == 0 : strcasestr(className.UTF8String, target_class) != NULL;
        if (match || (cluster && is_class_in_cluster(className.UTF8String, cluster))) {
            stats.object_count++;
            stats.total_size += nodeInfo.length;
            
            NSDictionary *objInfo = @{
                @"className": className,
                @"address": @(nodeInfo.address),
                @"length": @(nodeInfo.length),
                @"classInfo": classInfo
            };
            [stats.objects addObject:objInfo];
        }
    });
    
    if (stats.object_count > 0) {
        print_process_header(&stats);
        
        [stats.objects enumerateObjectsUsingBlock:^(NSDictionary *objInfo, NSUInteger idx, BOOL *stop) {
            VMUObjectGraphNode nodeInfo = {
                .address = [objInfo[@"address"] unsignedLongLongValue],
                .length = [objInfo[@"length"] unsignedLongLongValue],
                .classInfo = objInfo[@"classInfo"]
            };
            print_object_details(objInfo[@"className"], nodeInfo, nodeInfo.classInfo, scanner);
        }];
        
        printf("%s%s", ANSI_WHITE, BOX_BOT_LEFT);
        for (int i = 0; i < 80; i++) {
            printf(BOX_HORIZ);
        }
        printf("%s\n", ANSI_RESET);
    }
    
    [stats.objects release];
    ((void (*)(id, SEL))objc_msgSend)(scanner, sel_registerName("detachFromTask"));
    [scanner release];
    mach_port_deallocate(mach_task_self(), task);
}

static void *orig_printf = NULL;
static void new_printf(const char *format, ...) {
    if (format && strncmp(format, "    FAILED", 10) == 0) {
        return;
    }
    va_list args;
    va_start(args, format);
    vprintf(format, args);
    va_end(args);
}

__attribute__((constructor))
static void mute_decoder_failure_printfs(void) {
    void *substrate = dlopen("/var/jb/usr/lib/libsubstrate.dylib", RTLD_NOW);
    void *_MSHookFunction = dlsym(substrate, "MSHookFunction");
    if (_MSHookFunction) {
        ((void(*)(void *, void *, void **))_MSHookFunction)(printf, new_printf, &orig_printf);
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/Symbolication.framework/Symbolication", RTLD_NOW);
    
        if (argc != 2) {
            printf("Usage: %s <class_name>\n", argv[0]);
            printf("Example: %s NSString\n", argv[0]);
            return 1;
        }
        
        const char *target_class = argv[1];
        bool exact_match = false;

        int name[] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
        size_t proc_len = 0;
        if (sysctl(name, 4, NULL, &proc_len, NULL, 0) < 0) {
            printf("Failed to get process list length\n");
            return 1;
        }
        
        size_t proc_count = proc_len / sizeof(struct kinfo_proc);
        struct kinfo_proc *procs = malloc(proc_len);
        if (sysctl(name, 4, procs, &proc_len, NULL, 0) < 0) {
            printf("Failed to get process list\n");
            free(procs);
            return 1;
        }
        
        printf("\n");
        
        size_t processed = 0;
        printf(ANSI_CLEAR_LINE "Scanning processes: [                    ] 0%%  ");
        fflush(stdout);
        
        int saved_stderr = dup(STDERR_FILENO);
        int dev_null = open("/dev/null", O_WRONLY);
        dup2(dev_null, STDERR_FILENO);
        close(dev_null);
        
        for (int i = 0; i < proc_count; i++) {
            char *proc_name = procs[i].kp_proc.p_comm;
            pid_t pid = procs[i].kp_proc.p_pid;
            if (pid == 0 || pid == getpid()) {
                continue;
            }
            
            processed++;
            float progress = (float)processed / proc_count * 100;
            
            char progress_bar[22] = "[                    ]";
            int filled = (int)((progress / 100) * 20);
            for (int j = 0; j < filled; j++) {
                progress_bar[j + 1] = '=';
            }
            if (filled < 20) {
                progress_bar[filled + 1] = '>';
            }
            
            printf("\r%s%s %.1f%% - %s%s%s",
                   ANSI_CLEAR_LINE,
                   progress_bar, progress,
                   ANSI_YELLOW, proc_name, ANSI_RESET);
            fflush(stdout);
            
            if (should_scan_process(proc_name)) {
                
                scan_process_for_class_instances(proc_name, pid, target_class, exact_match);
                printf("%sScanning processes...%s", ANSI_WHITE, ANSI_RESET);
            }
        }
        
        printf("\n");

        dup2(saved_stderr, STDERR_FILENO);
        close(saved_stderr);
        free(procs);
        return 0;
    }
}
