//
//  class_clusters.h
//  objfind
//
//  Created by Ethan Arbuckle on 12/30/24.
//
#import <Foundation/Foundation.h>

#ifndef class_clusters_h
#define class_clusters_h


typedef struct {
    const char *base_class;
    const char **concrete_classes;
    size_t count;
} ClassCluster;

static const char *string_classes[] = {
    "NSString",
    "NSMutableString",
    "__NSCFString",
    "__NSCFConstantString",
    "NSTaggedPointerString",
    "__NSLocalizedString"
};

static const char *array_classes[] = {
    "NSArray",
    "NSMutableArray",
    "__NSArrayI",
    "__NSArrayM",
    "__NSSingleObjectArrayI",
    "__NSFrozenArrayM"
};

static const char *dictionary_classes[] = {
    "NSDictionary",
    "NSMutableDictionary",
    "__NSDictionaryI",
    "__NSDictionaryM",
    "__NSFrozenDictionaryM"
};

static const ClassCluster known_clusters[] = {
    { "NSString", string_classes, sizeof(string_classes) / sizeof(char *) },
    { "NSArray", array_classes, sizeof(array_classes) / sizeof(char *) },
    { "NSDictionary", dictionary_classes, sizeof(dictionary_classes) / sizeof(char *) }
};

static const ClassCluster *find_cluster_for_class(const char *class_name) {
    for (size_t i = 0; i < sizeof(known_clusters) / sizeof(ClassCluster); i++) {
        if (strcmp(known_clusters[i].base_class, class_name) == 0) {
            return &known_clusters[i];
        }
    }
    return NULL;
}

static bool is_class_in_cluster(const char *class_name, const ClassCluster *cluster) {
    if (!cluster) {
        return false;
    }
    
    for (size_t i = 0; i < cluster->count; i++) {
        if (strcmp(cluster->concrete_classes[i], class_name) == 0) {
            return true;
        }
    }
    return false;
}


#endif /* class_clusters_h */
