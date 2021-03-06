//
//  Xtrace.mm
//  Xtrace
//
//  Created by John Holdsworth on 28/02/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//
//  Repo: https://github.com/johnno1962/Xtrace
//
//  $Id: //depot/Xtrace/Xray/Xtrace.mm#43 $
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  Your milage will vary.. This is definitely a case of:
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
//  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
//  CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
//  TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
//  SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#ifdef DEBUG

#import "Xtrace.h"
#import <map>

#ifdef __clang__
#if __has_feature(objc_arc)
#define XTRACE_ISARC
#endif
#endif

#ifdef XTRACE_ISARC
#define XTRACE_BRIDGE(_type) (__bridge _type)
#define XTRACE_RETAINED __attribute((ns_returns_retained))
#else
#define XTRACE_BRIDGE(_type) (_type)
#define XTRACE_RETAINED
#endif

@implementation NSObject(Xtrace)

+ (void)notrace {
    [Xtrace dontTrace:self];
}

+ (void)xtrace {
    [Xtrace traceClass:self];
}

- (void)xtrace {
    [Xtrace traceInstance:self];
}

- (void)untrace {
    [Xtrace untrace:self];
}

@end

@implementation Xtrace

static BOOL includeProperties, hideReturns, showArguments = YES, describeValues, logToDelegate;
static id delegate;

+ (void)setDelegate:aDelegate {
    delegate = aDelegate;
    logToDelegate = [delegate respondsToSelector:@selector(xtraceLog:)];
}

+ (void)hideReturns:(BOOL)hide {
    hideReturns = hide;
}

+ (void)includeProperties:(BOOL)include {
    includeProperties = include;
}

+ (void)showArguments:(BOOL)show {
    showArguments = show;
}

+ (void)describeValues:(BOOL)desc {
    describeValues = desc;
}

static NSRegularExpression *includeMethods, *excludeMethods, *excludeTypes;
static NSString *methodBlackList = @"^(_UIAppearance_|drawRect:$)|WithObjects(AndKeys)?:$";

+ (NSRegularExpression *)methodRegexp:(NSString *)pattern {
    if ( !pattern )
        return nil;
    NSError *error = nil;
    NSRegularExpression *methodFilter = [[NSRegularExpression alloc] initWithPattern:pattern options:0 error:&error];
    if ( error )
        NSLog( @"Xtrace: Filter compilation error: %@, in pattern: \"%@\"", [error localizedDescription], pattern );
    return methodFilter;
}

+ (BOOL)includeMethods:(NSString *)pattern {
    return (includeMethods = [self methodRegexp:pattern]) != NULL;
}

+ (BOOL)excludeMethods:(NSString *)pattern {
    return (excludeMethods = [self methodRegexp:pattern]) != NULL;
}

+ (BOOL)excludeTypes:(NSString *)pattern {
    return (excludeTypes = [self methodRegexp:pattern]) != NULL;
}

static std::map<Class,std::map<SEL,struct _xtrace_info> > originals;
static std::map<Class,BOOL> tracedClasses, excludedClasses;
static std::map<void *,BOOL> tracedInstances;
static BOOL tracingInstances;
static int indent;

+ (void)dontTrace:(Class)aClass {
    Class metaClass = object_getClass(aClass);
    excludedClasses[metaClass] = 1;
    excludedClasses[aClass] = 1;
}

+ (void)traceClass:(Class)aClass {
    [self traceClass:aClass levels:10];
}

+ (void)traceClass:(Class)aClass levels:(int)levels {
    Class metaClass = object_getClass(aClass);
    [self traceClass:metaClass mtype:"+" levels:levels];
    [self traceClass:aClass mtype:"" levels:levels];
}

+ (void)traceInstance:(id)instance {
    tracedInstances[XTRACE_BRIDGE(void *)instance] = 1;
    [self traceClass:[instance class]];
    tracingInstances = YES;
}

+ (void)untrace:(id)instance {
    auto i = tracedInstances.find(XTRACE_BRIDGE(void *)instance);
    if ( i != tracedInstances.end() )
        tracedInstances.erase(i);
}

+ (void)forClass:(Class)aClass before:(SEL)sel callback:(SEL)callback {
    if ( !(originals[aClass][sel].before = [self forClass:aClass intercept:sel callback:callback]) )
        NSLog( @"Xtrace: ** Could not setup before callback for: [%s %s]", class_getName(aClass), sel_getName(sel) );
}

+ (void)forClass:(Class)aClass replace:(SEL)sel callback:(SEL)callback {
    if ( !(originals[aClass][sel].original = [self forClass:aClass intercept:sel callback:callback]) )
        NSLog( @"Xtrace: ** Could not setup replace callback for: [%s %s]", class_getName(aClass), sel_getName(sel) );
}

+ (void)forClass:(Class)aClass after:(SEL)sel callback:(SEL)callback {
    if ( !(originals[aClass][sel].after = [self forClass:aClass intercept:sel callback:callback]) )
        NSLog( @"Xtrace: ** Could not setup after callback for: [%s %s]", class_getName(aClass), sel_getName(sel) );
}

+ (VIMP)forClass:(Class)aClass intercept:(SEL)sel callback:(SEL)callback {
    int depth = [self depth:aClass];
    return [self intercept:aClass method:class_getInstanceMethod(aClass, sel) mtype:NULL depth:depth] ?
        (VIMP)[delegate methodForSelector:callback] : NULL;
}

+ (int)depth:(Class)aClass {
    int depth = 0;
    for ( Class tClass = aClass ; tClass != [NSObject class] &&
         tClass != object_getClass([NSObject class] ) ; tClass = class_getSuperclass(tClass) )
        depth++;
    return depth;
}

+ (void)traceClass:(Class)aClass mtype:(const char *)mtype levels:(int)levels {
    int depth = [self depth:aClass];
    tracedClasses[aClass] = 1;

    for ( int l=0 ; l<levels ; l++ ) {

        if ( excludedClasses.find(aClass) == excludedClasses.end() ) {
            unsigned mc = 0;
            Method *methods = class_copyMethodList(aClass, &mc);

            for( int i=0; methods && i<mc; i++ )
                [self intercept:aClass method:methods[i] mtype:mtype depth:depth];

            free( methods );
        }

        aClass = class_getSuperclass(aClass);
        if ( !--depth ) // don't trace NSObject
            break;
    }
}

+ (struct _xtrace_info *)infoFor:(Class)aClass sel:(SEL)sel {
    return &originals[aClass][sel];
}

// delegate can implement as instance method
+ (void)xtraceLog:(NSString *)trace {
    printf( "| %s\n", [trace UTF8String] );
}

static BOOL describing;

#define APPEND_TYPE( _enc, _fmt, _type ) case _enc: [args appendFormat:_fmt, va_arg(*argp,_type)]; return YES;

static BOOL formatValue( const char *type, void *valptr, va_list *argp, NSMutableString *args ) {
    switch ( type[0] == 'r' ? type[1] : type[0] ) {
        case 'V': case 'v':
            return NO;

        // warnings here are necessary evil
        // but how do I suppress them??
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wall"
        APPEND_TYPE( 'B', @"%d", BOOL )
        APPEND_TYPE( 'c', @"%d", char )
        APPEND_TYPE( 'C', @"%d", unsigned char )
        APPEND_TYPE( 's', @"%d", short )
        APPEND_TYPE( 'S', @"%d", unsigned short )
        APPEND_TYPE( 'i', @"%d", int )
        APPEND_TYPE( 'I', @"%u", unsigned )
        APPEND_TYPE( 'f', @"%f", float )
#pragma clang diagnostic pop
        APPEND_TYPE( 'd', @"%f", double )
        APPEND_TYPE( '^', @"%p", void * )
        APPEND_TYPE( '*', @"\"%.100s\"", char * )
#ifndef __LP64__
        APPEND_TYPE( 'q', @"%lldLL", long long )
#else
        case 'q':
#endif
        APPEND_TYPE( 'l', @"%ldL", long )
#ifndef __LP64__
        APPEND_TYPE( 'Q', @"%lluLL", unsigned long long )
#else
        case 'Q':
#endif
        APPEND_TYPE( 'L', @"%luL", unsigned long )
        case ':':
            [args appendFormat:@"@selector(%s)", sel_getName(va_arg(*argp,SEL))];
            return YES;
        case '#': case '@': {
            id obj = va_arg(*argp,id);
            if ( describeValues ) {
                describing = YES;
                [args appendString:obj?[obj description]:@"<nil>"];
                describing = NO;
            }
            else
                [args appendFormat:@"<%s %p>", class_getName(object_getClass(obj)), obj];
            return YES;
        }
        case '{':
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
            if ( strncmp(type,"{CGRect=",8) == 0 )
                [args appendString:NSStringFromCGRect( va_arg(*argp,CGRect) )];
            else if ( strncmp(type,"{CGPoint=",9) == 0 )
                [args appendString:NSStringFromCGPoint( va_arg(*argp,CGPoint) )];
            else if ( strncmp(type,"{CGSize=",8) == 0 )
                [args appendString:NSStringFromCGSize( va_arg(*argp,CGSize) )];
            else if ( strncmp(type,"{CGAffineTransform=",19) == 0 )
                [args appendString:NSStringFromCGAffineTransform( va_arg(*argp,CGAffineTransform) )];
            else if ( strncmp(type,"{UIEdgeInsets=",14) == 0 )
                [args appendString:NSStringFromUIEdgeInsets( va_arg(*argp,UIEdgeInsets) )];
            else if ( strncmp(type,"{UIOffset=",10) == 0 )
                [args appendString:NSStringFromUIOffset( va_arg(*argp,UIOffset) )];
#else
            if ( strncmp(type,"{_NSRect=",9) == 0 || strncmp(type,"{CGRect=",8) == 0 )
                [args appendString:NSStringFromRect( va_arg(*argp,NSRect) )];
            else if ( strncmp(type,"{_NSPoint=",10) == 0 || strncmp(type,"{CGPoint=",9) == 0 )
                [args appendString:NSStringFromPoint( va_arg(*argp,NSPoint) )];
            else if ( strncmp(type,"{_NSSize=",9) == 0 || strncmp(type,"{CGSize=",8) == 0 )
                [args appendString:NSStringFromSize( va_arg(*argp,NSSize) )];
#endif
            else if ( strncmp(type,"{_NSRange=",10) == 0 )
                [args appendString:NSStringFromRange( va_arg(*argp,NSRange) )];
            else
                break;
            return YES;
    }

    [args appendFormat:@"<?? %s>", type];
    return YES;
}

struct _xtrace_depth {
    int depth; id obj; SEL sel;
};

static id dummyImpl( id obj, SEL sel, ... ) {
    return nil;
}

// find struct _original implmentation for message and log call
static struct _xtrace_info &findOriginal( struct _xtrace_depth *info, SEL sel, ... ) {
    va_list argp; va_start(argp, sel);
    Class aClass = object_getClass( info->obj );

    while ( aClass && (originals[aClass].find(sel) == originals[aClass].end() ||
                       originals[aClass][sel].depth != info->depth) )
        aClass = class_getSuperclass( aClass );

    struct _xtrace_info &orig = originals[aClass][sel];
    void *thisObj = XTRACE_BRIDGE(void *)info->obj;

    if ( !aClass ) {
        NSLog( @"Xtrace: could not find original implementation for %s", sel_getName(info->sel) );
        orig.original = (VIMP)dummyImpl;
    }

    aClass = object_getClass( info->obj );
    if ( (orig.logged = !describing && orig.mtype &&
          (!tracingInstances ?
           tracedClasses.find(aClass) != tracedClasses.end() :
           tracedInstances.find(thisObj) != tracedInstances.end())) ) {
        NSMutableString *args = [NSMutableString string];

        [args appendFormat:@"%*s%s[<%s %p>", indent++, "",
         orig.mtype, class_getName(aClass), info->obj];

        if ( !showArguments )
            [args appendFormat:@" %s", orig.name];
        else {
            const char *frame = (char *)(void *)&info+sizeof info;
            void *valptr = &sel;

            for ( struct _xtrace_arg *aptr = orig.args ; *aptr->name ; aptr++ ) {
                [args appendFormat:@" %.*s", (int)(aptr[1].name-aptr->name), aptr->name];
                if ( !aptr->type )
                    break;

                valptr = (void *)(frame+aptr[1].stackOffset);
                formatValue( aptr->type, valptr, &argp, args );
            }
        }

        // add custom filtering of logging here..
        [args appendFormat:@"] %s %p", orig.type, orig.original];
        [logToDelegate ? delegate : [Xtrace class] xtraceLog:args];
    }

    orig.lastObj = thisObj;
    orig.stats.callCount++;
    orig.stats.entered = [NSDate timeIntervalSinceReferenceDate];

    return orig;
}

// log returning value
static void returning( struct _xtrace_info &orig, ... ) {
    va_list argp; va_start(argp, orig);
    indent && indent--;

    if ( orig.logged && !hideReturns ) {
        NSMutableString *val = [NSMutableString string];
        [val appendFormat:@"%*s-> ", indent, ""];
        if ( formatValue(orig.type, NULL, &argp, val) ) {
            [val appendFormat:@" (%s)", orig.name];
            [logToDelegate ? delegate : [Xtrace class] xtraceLog:val];
        }
    }

    orig.stats.elapsed = [NSDate timeIntervalSinceReferenceDate] - orig.stats.entered;
}

#define ARG_SIZE sizeof(id) + sizeof(SEL) + sizeof(void *)*9 // something may be aligned
#define ARG_DEFS void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7, void *a8, void *a9
#define ARG_COPY a0, a1, a2, a3, a4, a5, a6, a7, a8, a9

// replacement implmentations "swizzled" onto class
// "_depth" is number of levels down from NSObject
// (used to detect calls to super)
template <int _depth>
static void vimpl( id obj, SEL sel, ARG_DEFS ) {
    struct _xtrace_depth info = { _depth, obj, sel };
    struct _xtrace_info &orig = findOriginal( &info, sel, ARG_COPY );

    if ( orig.before && !orig.callingBack ) {
        orig.callingBack = YES;
        orig.before( delegate, sel, obj, ARG_COPY );
        orig.callingBack = NO;
    }

    orig.original( obj, sel, ARG_COPY );

    if ( orig.after && !orig.callingBack ) {
        orig.callingBack = YES;
        orig.after( delegate, sel, obj, ARG_COPY );
        orig.callingBack = NO;
    }

    returning( orig );
}

template <typename _type,int _depth>
static _type XTRACE_RETAINED intercept( id obj, SEL sel, ARG_DEFS ) {
    struct _xtrace_depth info = { _depth, obj, sel };
    struct _xtrace_info &orig = findOriginal( &info, sel, ARG_COPY );

    if ( orig.before && !orig.callingBack ) {
        orig.callingBack = YES;
        orig.before( delegate, sel, obj, ARG_COPY );
        orig.callingBack = NO;
    }

    _type (*impl)( id obj, SEL sel, ... ) = (_type (*)( id obj, SEL sel, ... ))orig.original;
    _type out = impl( obj, sel, ARG_COPY );

    if ( orig.after && !orig.callingBack ) {
        orig.callingBack = YES;
        impl = (_type (*)( id obj, SEL sel, ... ))orig.after;
        out = impl( delegate, sel, out, obj, ARG_COPY );
        orig.callingBack = NO;
    }

    returning( orig, out );
    return out;
}

+ (BOOL)intercept:(Class)aClass method:(Method)method mtype:(const char *)mtype depth:(int)depth {
    SEL sel = method_getName(method);
    const char *name = sel_getName(sel);
    const char *className = class_getName(aClass);
    const char *type = method_getTypeEncoding(method);

    IMP newImpl = NULL;
    switch ( type[0] == 'r' ? type[1] : type[0] ) {
        case 'V':
        case 'v':
            switch (depth%10) {
                case 0: newImpl = (IMP)vimpl<0>; break;
                case 1: newImpl = (IMP)vimpl<1>; break;
                case 2: newImpl = (IMP)vimpl<2>; break;
                case 3: newImpl = (IMP)vimpl<3>; break;
                case 4: newImpl = (IMP)vimpl<4>; break;
                case 5: newImpl = (IMP)vimpl<5>; break;
                case 6: newImpl = (IMP)vimpl<6>; break;
                case 7: newImpl = (IMP)vimpl<7>; break;
                case 8: newImpl = (IMP)vimpl<8>; break;
                case 9: newImpl = (IMP)vimpl<9>; break;
            }
            break;

#define IMPLS( _type ) switch ( depth%10 ) { \
    case 0: newImpl = (IMP)intercept<_type,0>; break; \
    case 1: newImpl = (IMP)intercept<_type,1>; break; \
    case 2: newImpl = (IMP)intercept<_type,2>; break; \
    case 3: newImpl = (IMP)intercept<_type,3>; break; \
    case 4: newImpl = (IMP)intercept<_type,4>; break; \
    case 5: newImpl = (IMP)intercept<_type,5>; break; \
    case 6: newImpl = (IMP)intercept<_type,6>; break; \
    case 7: newImpl = (IMP)intercept<_type,7>; break; \
    case 8: newImpl = (IMP)intercept<_type,8>; break; \
    case 9: newImpl = (IMP)intercept<_type,9>; break; \
}

        case 'B': IMPLS( bool ); break;
        case 'C':
        case 'c': IMPLS( char ); break;
        case 'S':
        case 's': IMPLS( short ); break;
        case 'I':
        case 'i': IMPLS( int ); break;
        case 'Q':
        case 'q':
#ifndef __LP64__
            IMPLS( long long ); break;
#endif
        case 'L':
        case 'l': IMPLS( long ); break;
        case 'f': IMPLS( float ); break;
        case 'd': IMPLS( double ); break;
        case '#':
        case '@': IMPLS( id ); break;
        case '^': IMPLS( void * ); break;
        case ':': IMPLS( SEL ); break;
        case '*': IMPLS( char * ); break;
        case '{':
            if ( strncmp(type,"{_NSRange=",10) == 0 )
                IMPLS( NSRange )
#ifndef __IPHONE_OS_VERSION_MIN_REQUIRED
            else if ( strncmp(type,"{_NSRect=",9) == 0 )
                IMPLS( NSRect )
            else if ( strncmp(type,"{_NSPoint=",10) == 0 )
                IMPLS( NSPoint )
            else if ( strncmp(type,"{_NSSize=",9) == 0 )
                IMPLS( NSSize )
#endif
            else if ( strncmp(type,"{CGRect=",8) == 0 )
                IMPLS( CGRect )
            else if ( strncmp(type,"{CGPoint=",9) == 0 )
                IMPLS( CGPoint )
            else if ( strncmp(type,"{CGSize=",8) == 0 )
                IMPLS( CGSize )
            else if ( strncmp(type,"{CGAffineTransform=",19) == 0 )
                IMPLS( CGAffineTransform )
            break;
        default:
            NSLog(@"Xtrace: Unsupported return type: %s for: %s[%s %s]", type, mtype, className, name);
    }

    NSString *methodName = [NSString stringWithUTF8String:name];
    const char *frameSize = type+1;
    while ( !isdigit(*frameSize) )
        frameSize++;

    // yes, this is a hack
    if ( !excludeMethods )
        [self excludeMethods:methodBlackList];

    // filters applied only when not a callback registration (mtype == NULL)
    if ( ((includeMethods && ![self string:methodName matches:includeMethods]) ||
        (excludeMethods && [self string:methodName matches:excludeMethods])) && mtype )
        NSLog( @"Xtrace: filters exclude: %s[%s %s] %s", mtype, className, name, type );

    else if ( (excludeTypes && [self string:[NSString stringWithUTF8String:type] matches:excludeTypes]) && mtype )
        NSLog( @"Xtrace: type filter excludes: %s[%s %s] %s", mtype, className, name, type );

    else if ( atoi(frameSize) > ARG_SIZE )
        NSLog( @"Xtrace: Stack frame too large to trace method: %s[%s %s]",
              mtype, className, name );

    else if ( newImpl && name[0] != '.' && //strcmp(name,"initialize") != 0 &&
             strcmp(name,"retain") != 0 && strcmp(name,"release") != 0 &&
             strcmp(name,"dealloc") != 0 && strcmp(name,"description") != 0 &&
             (includeProperties || !mtype || !class_getProperty( aClass, name )) ) {

        struct _xtrace_info &orig = originals[aClass][sel];

        orig.name = name;
        orig.type = type;
        orig.method = method;
        orig.depth = depth%10;
        if ( mtype )
            orig.mtype = mtype;

        [self extractSelector:name into:orig.args];
        [self extractOffsets:type into:orig.args];

        IMP impl = method_getImplementation(method);
        if ( impl != newImpl ) {
            orig.original = (VIMP)impl;
            method_setImplementation(method,newImpl);
            //NSLog( @"%d %s%s %s %s", depth, mtype, className, name, type );
        }

        return YES;
    }

    return NO;
}

+ (BOOL)string:(NSString *)name matches:(NSRegularExpression *)regexp {
    return [regexp rangeOfFirstMatchInString:name options:0 range:NSMakeRange(0, [name length])].location != NSNotFound;
}

// break up selector by argument
+ (int)extractSelector:(const char *)name into:(struct _xtrace_arg *)args {

    for ( int i=0 ; i<XTRACE_ARGS_SUPPORTED ; i++ ) {
        args->name = name;
        const char *next = index( name, ':' );
        if ( next ) {
            name = next+1;
            args++;
        }
        else {
            args[1].name = name+strlen(name);
            return i;
        }
    }

    return -1;
}

// parse method encoding for call stack offsets (replaced by varargs)

#if 1 // original version using information in method type encoding

+ (int)extractOffsets:(const char *)type into:(struct _xtrace_arg *)args {
    int frameLen = -1;

    for ( int i=0 ; i<XTRACE_ARGS_SUPPORTED ; i++ ) {
        args->type = type;
        while ( !isdigit(*type) )
            type++;
        args->stackOffset = -atoi(type);
        if ( i==0 )
            frameLen = args->stackOffset;
        while ( isdigit(*type) )
            type++;
        if ( i>2 )
            args++;
        else
            args->type = NULL;
        if ( !*type ) {
            args->stackOffset = frameLen;
            return i;
        }
    }

    return -1;
}

#else // alternate "NSGetSizeAndAlignment()" version

+ (int)extractOffsets:(const char *)type into:(struct _xtrace_arg *)args {
    NSUInteger size, align, offset = 0;

    type = NSGetSizeAndAlignment( type, &size, &align );

    for ( int i=0 ; i<XTRACE_ARGS_SUPPORTED ; i++ ) {
        while ( isdigit(*type) )
            type++;
        args->type = type;
        type = NSGetSizeAndAlignment( type, &size, &align );
        if ( !*type )
            return i;
        offset -= size;
        offset &= ~(align-1 | sizeof(void *)-1);
        args[1].stackOffset = (int)offset;
        if ( i>1 )
            args++;
        else
            args->type = NULL;
    }

    return -1;
}

#endif
@end
#endif
