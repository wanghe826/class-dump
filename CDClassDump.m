//  This file is part of class-dump, a utility for examining the
//  Objective-C segment of Mach-O files.
//  Copyright (C) 1997-1998, 2000-2001, 2004  Steve Nygard

#import "CDClassDump.h"

#import "rcsid.h"
#import <Foundation/Foundation.h>
#import "NSArray-Extensions.h"
#import "CDDylibCommand.h"
#import "CDMachOFile.h"
#import "CDObjCSegmentProcessor.h"
#import "CDStructureTable.h"
#import "CDSymbolReferences.h"
#import "CDType.h"
#import "CDTypeFormatter.h"
#import "CDTypeParser.h"

RCS_ID("$Header: /Volumes/Data/tmp/Tools/class-dump/CDClassDump.m,v 1.55 2004/02/02 22:39:30 nygard Exp $");

@implementation CDClassDump2

static NSMutableSet *wrapperExtensions = nil;

+ (void)initialize;
{
    // TODO (old): Try grabbing these from an environment variable.
    wrapperExtensions = [[NSMutableSet alloc] init];
    [wrapperExtensions addObject:@"app"];
    [wrapperExtensions addObject:@"framework"];
    [wrapperExtensions addObject:@"bundle"];
    [wrapperExtensions addObject:@"palette"];
    [wrapperExtensions addObject:@"plugin"];
}

// How does this handle something ending in "/"?

+ (BOOL)isWrapperAtPath:(NSString *)path;
{
    return [wrapperExtensions containsObject:[path pathExtension]];
}

+ (NSString *)pathToMainFileOfWrapper:(NSString *)wrapperPath;
{
    NSString *base, *extension, *mainFile;

    base = [wrapperPath lastPathComponent];
    extension = [base pathExtension];
    base = [base stringByDeletingPathExtension];

    if ([@"framework" isEqual:extension] == YES) {
        mainFile = [NSString stringWithFormat:@"%@/%@", wrapperPath, base];
    } else {
        // app, bundle, palette, plugin
        mainFile = [NSString stringWithFormat:@"%@/Contents/MacOS/%@", wrapperPath, base];
    }

    return mainFile;
}

// Allow user to specify wrapper instead of the actual Mach-O file.
+ (NSString *)adjustUserSuppliedPath:(NSString *)path;
{
    NSString *fullyResolvedPath, *basePath, *resolvedBasePath;

    if ([self isWrapperAtPath:path] == YES) {
        path = [self pathToMainFileOfWrapper:path];
    }

    fullyResolvedPath = [path stringByResolvingSymlinksInPath];
    basePath = [path stringByDeletingLastPathComponent];
    resolvedBasePath = [basePath stringByResolvingSymlinksInPath];
    NSLog(@"fullyResolvedPath: %@", fullyResolvedPath);
    NSLog(@"basePath:          %@", basePath);
    NSLog(@"resolvedBasePath:  %@", resolvedBasePath);

    // I don't want to resolve all of the symlinks, just the ones starting from the wrapper.
    // If I have a symlink from my home directory to /System/Library/Frameworks/AppKit.framework, I want to see the
    // path to my home directory.
    // This is an easy way to cheat so that we don't have to deal with NSFileManager ourselves.
    return [basePath stringByAppendingString:[fullyResolvedPath substringFromIndex:[resolvedBasePath length]]];
}

- (id)init;
{
    if ([super init] == nil)
        return nil;

    executablePath = nil;

    //machOFiles = [[NSMutableArray alloc] init];
    machOFilesByID = [[NSMutableDictionary alloc] init];
    objCSegmentProcessors = [[NSMutableArray alloc] init];

    structureTable = [[CDStructureTable alloc] init];
    [structureTable setAnonymousBaseName:@"CDAnonymousStruct"];
    [structureTable setName:@"Structs"];

    unionTable = [[CDStructureTable alloc] init];
    [unionTable setAnonymousBaseName:@"CDAnonymousUnion"];
    [unionTable setName:@"Unions"];

    ivarTypeFormatter = [[CDTypeFormatter alloc] init];
    [ivarTypeFormatter setShouldExpand:NO];
    [ivarTypeFormatter setShouldAutoExpand:YES];
    [ivarTypeFormatter setBaseLevel:1];
    [ivarTypeFormatter setDelegate:self];

    methodTypeFormatter = [[CDTypeFormatter alloc] init];
    [methodTypeFormatter setShouldExpand:NO];
    [methodTypeFormatter setShouldAutoExpand:NO];
    [methodTypeFormatter setBaseLevel:0];
    [methodTypeFormatter setDelegate:self];

    structDeclarationTypeFormatter = [[CDTypeFormatter alloc] init];
    [structDeclarationTypeFormatter setShouldExpand:YES]; // But don't expand named struct members...
    [structDeclarationTypeFormatter setShouldAutoExpand:YES];
    [structDeclarationTypeFormatter setBaseLevel:0];
    [structDeclarationTypeFormatter setDelegate:self]; // But need to ignore some things?

    frameworkNamesByClassName = [[NSMutableDictionary alloc] init];

    return self;
}

- (void)dealloc;
{
    [executablePath release];
    [outputPath release];

    [machOFilesByID release];
    [objCSegmentProcessors release];

    [structureTable release];
    [unionTable release];

    [ivarTypeFormatter release];
    [methodTypeFormatter release];
    [structDeclarationTypeFormatter release];

    [frameworkNamesByClassName release];

    [super dealloc];
}

- (NSString *)executablePath;
{
    return executablePath;
}

- (void)setExecutablePath:(NSString *)newPath;
{
    if (newPath == executablePath)
        return;

    [executablePath release];
    executablePath = [newPath retain];

    NSLog(@"%s, executablePath: %@", _cmd, executablePath);
}

- (BOOL)shouldProcessRecursively;
{
    return shouldProcessRecursively;
}

- (void)setShouldProcessRecursively:(BOOL)newFlag;
{
    shouldProcessRecursively = newFlag;
}

- (BOOL)shouldGenerateSeparateHeaders;
{
    return shouldGenerateSeparateHeaders;
}

- (void)setShouldGenerateSeparateHeaders:(BOOL)newFlag;
{
    shouldGenerateSeparateHeaders = newFlag;
}

- (BOOL)shouldSort;
{
    return shouldSort;
}

- (void)setShouldSort:(BOOL)newFlag;
{
    shouldSort = newFlag;
}

- (NSString *)outputPath;
{
    return outputPath;
}

- (void)setOutputPath:(NSString *)aPath;
{
    if (aPath == outputPath)
        return;

    [aPath release];
    outputPath = [aPath retain];
}

- (CDStructureTable *)structureTable;
{
    return structureTable;
}

- (CDStructureTable *)unionTable;
{
    return unionTable;
}

- (CDTypeFormatter *)ivarTypeFormatter;
{
    return ivarTypeFormatter;
}

- (CDTypeFormatter *)methodTypeFormatter;
{
    return methodTypeFormatter;
}

- (CDTypeFormatter *)structDeclarationTypeFormatter;
{
    return structDeclarationTypeFormatter;
}

- (void)processFilename:(NSString *)aFilename;
{
    NSString *adjustedPath;

    adjustedPath = [[self class] adjustUserSuppliedPath:aFilename];
    [self setExecutablePath:[adjustedPath stringByDeletingLastPathComponent]];
    [self _processFilename:adjustedPath];
}

- (void)_processFilename:(NSString *)aFilename;
{
    CDMachOFile *aMachOFile;
    CDObjCSegmentProcessor *aProcessor;

    //NSLog(@" > %s", _cmd);
    //NSLog(@"aFilename: %@", aFilename);

    aMachOFile = [[CDMachOFile alloc] initWithFilename:aFilename];
    [aMachOFile setDelegate:self];
    [aMachOFile process];

    aProcessor = [[CDObjCSegmentProcessor alloc] initWithMachOFile:aMachOFile];
    [aProcessor process];
    [objCSegmentProcessors addObject:aProcessor];
    [aProcessor release];

    [machOFilesByID setObject:aMachOFile forKey:aFilename];

    [aMachOFile release];

    //NSLog(@"<  %s", _cmd);
}

- (void)doSomething;
{
    NSLog(@"machOFilesByID keys: %@", [[machOFilesByID allKeys] description]);
    //NSLog(@"machOFiles in order: %@", [[machOFiles arrayByMappingSelector:@selector(filename)] description]);
    //NSLog(@"objCSegmentProcessors in order: %@", [objCSegmentProcessors description]);

    [self registerPhase:1];
    [self registerPhase:2];
    [self generateMemberNames];

    if ([self shouldGenerateSeparateHeaders] == YES)
        [self generateSeparateHeaders];
    else
        [self generateToStandardOut];
}

- (void)generateToStandardOut;
{
    NSMutableString *resultString;
    int count, index;
    NSData *data;

    resultString = [[NSMutableString alloc] init];

    [self appendHeaderToString:resultString];
    [self appendStructuresToString:resultString symbolReferences:nil];

    count = [objCSegmentProcessors count];
    for (index = 0; index < count; index++) {
        [[objCSegmentProcessors objectAtIndex:index] appendFormattedStringSortedByClass:resultString classDump:self];
    }

    data = [resultString dataUsingEncoding:NSUTF8StringEncoding];
    [(NSFileHandle *)[NSFileHandle fileHandleWithStandardOutput] writeData:data];

    [resultString release];
}

- (void)generateSeparateHeaders;
{
    int count, index;

    [self buildClassFrameworks];

    if (outputPath != nil) {
        NSFileManager *fileManager;
        BOOL isDirectory;

        fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:outputPath isDirectory:&isDirectory] == NO) {
            BOOL result;

            result = [fileManager createDirectoryAtPath:outputPath attributes:nil];
            if (result == NO) {
                NSLog(@"Couldn't create output directory: %@", outputPath);
                return;
            }
        } else if (isDirectory == NO) {
            NSLog(@"File exists at output path: %@", outputPath);
            return;
        }
    }

    [self generateStructureHeader];

    count = [objCSegmentProcessors count];
    for (index = 0; index < count; index++) {
        [[objCSegmentProcessors objectAtIndex:index] generateSeparateHeadersClassDump:self];
    }
}

- (void)generateStructureHeader;
{
    NSMutableString *resultString;
    NSString *filename;
    CDSymbolReferences *symbolReferences;
    NSString *referenceString;
    unsigned int referenceIndex;

    resultString = [[NSMutableString alloc] init];
    [self appendHeaderToString:resultString];

    symbolReferences = [[CDSymbolReferences alloc] init];
    referenceIndex = [resultString length];

    [self appendStructuresToString:resultString symbolReferences:symbolReferences];

    referenceString = [symbolReferences referenceString];
    if (referenceString != nil)
        [resultString insertString:referenceString atIndex:referenceIndex];

    filename = @"CDStructures.h";
    if (outputPath != nil)
        filename = [outputPath stringByAppendingPathComponent:filename];

    [[resultString dataUsingEncoding:NSUTF8StringEncoding] writeToFile:filename atomically:YES];

    [symbolReferences release];
    [resultString release];
}

- (void)logInfo;
{
    [structureTable logInfo];
    [unionTable logInfo];
}

- (void)appendStructuresToString:(NSMutableString *)resultString symbolReferences:(CDSymbolReferences *)symbolReferences;
{
    [structureTable appendNamedStructuresToString:resultString formatter:structDeclarationTypeFormatter symbolReferences:symbolReferences];
    [structureTable appendTypedefsToString:resultString formatter:structDeclarationTypeFormatter symbolReferences:symbolReferences];

    [unionTable appendNamedStructuresToString:resultString formatter:structDeclarationTypeFormatter symbolReferences:symbolReferences];
    [unionTable appendTypedefsToString:resultString formatter:structDeclarationTypeFormatter symbolReferences:symbolReferences];
}

- (CDMachOFile *)machOFileWithID:(NSString *)anID;
{
    NSString *adjustedID;
    CDMachOFile *aMachOFile;
    NSString *replacementString = @"@executable_path";

    //NSLog(@" > %s", _cmd);
    //NSLog(@"anID: %@", anID);
    if ([anID hasPrefix:replacementString] == YES) {
        adjustedID = [executablePath stringByAppendingString:[anID substringFromIndex:[replacementString length]]];
    } else {
        adjustedID = anID;
    }
    //NSLog(@"adjustedID: %@", adjustedID);

    aMachOFile = [machOFilesByID objectForKey:adjustedID];
    if (aMachOFile == nil) {
        [self _processFilename:adjustedID];
        aMachOFile = [machOFilesByID objectForKey:adjustedID];
    }
    //NSLog(@"<  %s", _cmd);

    return aMachOFile;
}

- (void)machOFile:(CDMachOFile *)aMachOFile loadDylib:(CDDylibCommand *)aDylibCommand;
{
    //NSLog(@" > %s", _cmd);
    //NSLog(@"aDylibCommand: %@", aDylibCommand);

    if ([aDylibCommand cmd] == LC_LOAD_DYLIB && shouldProcessRecursively == YES) {
        //NSLog(@"Load it!");
        [self machOFileWithID:[aDylibCommand name]];
    }

    //NSLog(@"<  %s", _cmd);
}

- (void)appendHeaderToString:(NSMutableString *)resultString;
{
    [resultString appendString:@"/*\n"];
    [resultString appendFormat:@" *     Generated by class-dump (version %@).\n", CLASS_DUMP_VERSION];
    [resultString appendString:@" *\n"];
    [resultString appendString:@" *     class-dump is Copyright (C) 1997-1998, 2000-2001, 2004 by Steve Nygard.\n"];
    [resultString appendString:@" */\n\n"];
}

- (CDType *)typeFormatter:(CDTypeFormatter *)aFormatter replacementForType:(CDType *)aType;
{
    if ([aType type] == '{')
        return [structureTable replacementForType:aType];

    if ([aType type] == '(')
        return [unionTable replacementForType:aType];

    return nil;
}

- (NSString *)typeFormatter:(CDTypeFormatter *)aFormatter typedefNameForStruct:(CDType *)structType level:(int)level;
{
    CDType *replacementType, *searchType;
    CDStructureTable *targetTable;

    if (level == 0 && aFormatter == structDeclarationTypeFormatter)
        return nil;

    if ([structType type] == '{') {
        targetTable = structureTable;
    } else {
        targetTable = unionTable;
    }

    // We need to catch top level replacements, not just replacements for struct members.
    replacementType = [targetTable replacementForType:structType];
    if (replacementType != nil)
        searchType = replacementType;
    else
        searchType = structType;

    return [targetTable typedefNameForStructureType:searchType];
}

- (void)registerPhase:(int)phase;
{
    NSAutoreleasePool *pool;
    int count, index;

    //NSLog(@"Phase %d ========================================", phase);

    pool = [[NSAutoreleasePool alloc] init];

    count = [objCSegmentProcessors count];
    for (index = 0; index < count; index++) {
        [[objCSegmentProcessors objectAtIndex:index] registerStructuresWithObject:self phase:phase];
    }

    [self endPhase:phase];
    [pool release];
}

- (void)endPhase:(int)phase;
{
    if (phase == 1) {
        //[structureTable logPhase1Data];
        //[unionTable logPhase1Data];

        [structureTable finishPhase1];
        [unionTable finishPhase1];
    } else if (phase == 2) {
        //[structureTable logInfo];
        //[unionTable logInfo];

        [structureTable generateNamesForAnonymousStructures];
        [unionTable generateNamesForAnonymousStructures];
    }
}

- (void)phase1RegisterStructure:(CDType *)aStructure;
{
    if ([aStructure type] == '{') {
        [structureTable phase1RegisterStructure:aStructure];
    } else if ([aStructure type] == '(') {
        [unionTable phase1RegisterStructure:aStructure];
    } else {
        NSLog(@"%s, unknown structure type: %d", _cmd, [aStructure type]);
    }
}

- (BOOL)phase2RegisterStructure:(CDType *)aStructure usedInMethod:(BOOL)isUsedInMethod countReferences:(BOOL)shouldCountReferences;
{
    if ([aStructure type] == '{') {
        return [structureTable phase2RegisterStructure:aStructure withObject:self usedInMethod:isUsedInMethod countReferences:shouldCountReferences];
    } else if ([aStructure type] == '(') {
        return [unionTable phase2RegisterStructure:aStructure withObject:self usedInMethod:isUsedInMethod countReferences:shouldCountReferences];
    } else {
        NSLog(@"%s, unknown structure type: %d", _cmd, [aStructure type]);
    }

    return NO;
}

- (void)generateMemberNames;
{
    [structureTable generateMemberNames];
    [unionTable generateMemberNames];
}

- (void)buildClassFrameworks;
{
    [objCSegmentProcessors makeObjectsPerformSelector:@selector(registerClassesWithObject:) withObject:frameworkNamesByClassName];
}

- (NSString *)frameworkForClassName:(NSString *)aClassName;
{
    return [frameworkNamesByClassName objectForKey:aClassName];
}

- (void)appendImportForClassName:(NSString *)aClassName toString:(NSMutableString *)resultString;
{
    if (aClassName != nil) {
        NSString *classFramework;

        classFramework = [self frameworkForClassName:aClassName];
        if (classFramework == nil)
            [resultString appendFormat:@"#import \"%@.h\"\n\n", aClassName];
        else
            [resultString appendFormat:@"#import <%@/%@.h>\n\n", classFramework, aClassName];
    }
}

@end
