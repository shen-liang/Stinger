//
//  STHookInfoPool.m
//  Stinger
//
//  Created by Assuner on 2018/1/9.
//  Copyright © 2018年 Assuner. All rights reserved.
//

#import "STHookInfoPool.h"
#import <Stinger/ffi.h>
#import "STBlock.h"
#import "STMethodSignature.h"
#import <objc/runtime.h>

NSString * const STClassPrefix = @"st_class_";
NSString * const STSelectorPrefix = @"st_sel";

@interface STHookInfoPool ()
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, strong) STMethodSignature *signature;
@property (nonatomic, strong) NSMethodSignature *ns_signature;
@end

@implementation STHookInfoPool {
  ffi_cif _cif;
  ffi_cif _blockCif;
  ffi_type **_args;
  ffi_type **_blockArgs;
  ffi_closure *_closure;
}


@synthesize beforeInfos = _beforeInfos;
@synthesize insteadInfos = _insteadInfos;
@synthesize afterInfos = _afterInfos;
@synthesize identifiers = _identifiers;
@synthesize originalIMP = _originalIMP;
@synthesize typeEncoding = _typeEncoding;
@synthesize sel = _sel;
@synthesize cls = _cls;


+ (instancetype)poolWithTypeEncoding:(NSString *)typeEncoding originalIMP:(IMP)imp selector:(SEL)sel {
  STHookInfoPool *pool = [[STHookInfoPool alloc] init];
  pool.typeEncoding = typeEncoding;
  pool.originalIMP = imp;
  pool.sel = sel;
  return pool;
}

- (instancetype)init {
  if (self = [super init]) {
    _beforeInfos = [[NSMutableArray alloc] init];
    _insteadInfos = [[NSMutableArray alloc] init];
    _afterInfos = [[NSMutableArray alloc] init];
    _identifiers = [[NSMutableArray alloc] init];
    _lock = [[NSLock alloc] init];
  }
  return self;
}

- (void)setTypeEncoding:(NSString *)typeEncoding {
  _typeEncoding = typeEncoding;
  _signature = typeEncoding ? [[STMethodSignature alloc] initWithObjCTypes:typeEncoding] : nil;
  _ns_signature = typeEncoding ? [NSMethodSignature signatureWithObjCTypes:[typeEncoding UTF8String]]: nil;
}

- (BOOL)addInfo:(id<STHookInfo>)info {
  NSParameterAssert(info);
  [_lock lock];
  if (![_identifiers containsObject:info.identifier]) {
    switch (info.option) {
      case STOptionBefore: {
        [_beforeInfos addObject:info];
        break;
      }
      case STOptionInstead: {
        [_insteadInfos removeAllObjects];
        [_insteadInfos addObject:info];
        break;
      }
      case STOptionAfter:
      default: {
        [_afterInfos addObject:info];
        break;
      }
    }
    [_identifiers addObject:info.identifier];
    [_lock unlock];
    return YES;
  }
  NSAssert(NO, @"Class (%@) has had identifier (%@) with SEL (%@)", self.cls, info.identifier, NSStringFromSelector(self.sel));
  return NO;
}

- (BOOL)removeInfoForIdentifier:(STIdentifier)identifier {
  if ([self _removeInfoForIdentifier:identifier inInfos:self.beforeInfos]) return YES;
  if ([self _removeInfoForIdentifier:identifier inInfos:self.insteadInfos]) return YES;
  if ([self _removeInfoForIdentifier:identifier inInfos:self.afterInfos]) return YES;
  
  return NO;
}

- (BOOL)_removeInfoForIdentifier:(STIdentifier)identifier inInfos:(NSMutableArray<id<STHookInfo>> *)infos {
  [_lock lock];
  BOOL flag = NO;
  for (int i = 0; i < infos.count; i ++) {
    id<STHookInfo> info = infos[i];
    if ([info.identifier isEqualToString:identifier]) {
      [infos removeObject:info];
      [_identifiers removeObject:identifier];
      flag = YES;
      break;
    }
  }
  [_lock unlock];
  return flag;
}

- (StingerIMP)stingerIMP {
  ffi_type *returnType = ffiTypeWithType(self.signature.returnType);
  NSAssert(returnType, @"can't find a ffi_type of %@", self.signature.returnType);
  
  NSUInteger argumentCount = self.signature.argumentTypes.count;
  StingerIMP stingerIMP = NULL;
  _args = malloc(sizeof(ffi_type *) * argumentCount) ;
  
  for (int i = 0; i < argumentCount; i++) {
    ffi_type* current_ffi_type = ffiTypeWithType(self.signature.argumentTypes[i]);
    NSAssert(current_ffi_type, @"can't find a ffi_type of %@", self.signature.argumentTypes[i]);
    _args[i] = current_ffi_type;
  }
  
  _closure = ffi_closure_alloc(sizeof(ffi_closure), (void **)&stingerIMP);
  
  if(ffi_prep_cif(&_cif, FFI_DEFAULT_ABI, (unsigned int)argumentCount, returnType, _args) == FFI_OK) {
    if (ffi_prep_closure_loc(_closure, &_cif, ffi_function, (__bridge void *)(self), stingerIMP) != FFI_OK) {
      NSAssert(NO, @"genarate IMP failed");
    }
  } else {
    NSAssert(NO, @"FUCK");
  }
  
  [self _genarateBlockCif];
  return stingerIMP;
}

- (void)_genarateBlockCif {
  ffi_type *returnType = ffiTypeWithType(self.signature.returnType);
  
  NSUInteger argumentCount = self.signature.argumentTypes.count;
  _blockArgs = malloc(sizeof(ffi_type *) *argumentCount);
  
  ffi_type *current_ffi_type_0 = ffiTypeWithType(@"@?");
  _blockArgs[0] = current_ffi_type_0;
  ffi_type *current_ffi_type_1 = ffiTypeWithType(@"@");
  _blockArgs[1] = current_ffi_type_1;
  
  for (int i = 2; i < argumentCount; i++){
    ffi_type* current_ffi_type = ffiTypeWithType(self.signature.argumentTypes[i]);
    _blockArgs[i] = current_ffi_type;
  }
  
  if(ffi_prep_cif(&_blockCif, FFI_DEFAULT_ABI, (unsigned int)argumentCount, returnType, _blockArgs) != FFI_OK) {
    NSAssert(NO, @"FUCK");
  }
}

- (void)dealloc {
  ffi_closure_free(_closure);
  free(_args);
  free(_blockArgs);
}

id<STHookInfoPool> st_getHookInfoPool(id obj, SEL key) {
  NSCParameterAssert(obj);
  NSCParameterAssert(key);
  return objc_getAssociatedObject(obj, NSSelectorFromString([STSelectorPrefix stringByAppendingString:NSStringFromSelector(key)]));
}

void st_setHookInfoPool(id obj, SEL key, id<STHookInfoPool> infoPool) {
  NSCParameterAssert(obj);
  NSCParameterAssert(key);
  objc_setAssociatedObject(obj, NSSelectorFromString([STSelectorPrefix stringByAppendingString:NSStringFromSelector(key)]), infoPool, OBJC_ASSOCIATION_RETAIN);
}

#define ffi_call_infos(infos) \
for (id<STHookInfo> info in infos) { \
  id block = info.block; \
  innerArgs[0] = &block; \
  ffi_call(&(isaClassHookInfoPool->_blockCif), impForBlock(block), NULL, innerArgs); \
}  \

static void ffi_function(ffi_cif *cif, void *ret, void **args, void *userdata) {
  STHookInfoPool *isaClassHookInfoPool = (__bridge STHookInfoPool *)userdata;
  STHookInfoPool *originalClassHookInfoPool = nil;
  STHookInfoPool *instanceHookInfoPool = nil;
  Class isaClass = isaClassHookInfoPool.cls;
  SEL key = isaClassHookInfoPool.sel;
  if ([NSStringFromClass(isaClass) hasPrefix:STClassPrefix]) {
    originalClassHookInfoPool = st_getHookInfoPool(class_getSuperclass(isaClass), key); // may be nil
  } else {
    originalClassHookInfoPool = isaClassHookInfoPool;
  }
  NSUInteger count = isaClassHookInfoPool.signature.argumentTypes.count;
  void **innerArgs = malloc(count * sizeof(*innerArgs));
  StingerParams *params = [[StingerParams alloc] init];
  void **slf = args[0];
  instanceHookInfoPool = st_getHookInfoPool((__bridge id)(*slf), key);
  params.slf = (__bridge id)(*slf);
  params.sel = isaClassHookInfoPool.sel;
  [params addOriginalIMP:isaClassHookInfoPool.originalIMP];
  NSInvocation *originalInvocation = [NSInvocation invocationWithMethodSignature:isaClassHookInfoPool.ns_signature];
  for (int i = 0; i < count; i ++) {
    [originalInvocation setArgument:args[i] atIndex:i];
  }
  [params addOriginalInvocation:originalInvocation];
  
  innerArgs[1] = &params;
  memcpy(innerArgs + 2, args + 2, (count - 2) * sizeof(*args));
  
  // before hooks
  ffi_call_infos(originalClassHookInfoPool.beforeInfos);
  ffi_call_infos(instanceHookInfoPool.beforeInfos);
  
  // instead hooks
  if (instanceHookInfoPool.insteadInfos.count) {
    id <STHookInfo> info = instanceHookInfoPool.insteadInfos[0];
    id block = info.block;
    innerArgs[0] = &block;
    ffi_call(&(isaClassHookInfoPool->_blockCif), impForBlock(block), ret, innerArgs);
  } else if (originalClassHookInfoPool.insteadInfos.count) {
    id <STHookInfo> info = originalClassHookInfoPool.insteadInfos[0];
    id block = info.block;
    innerArgs[0] = &block;
    ffi_call(&(isaClassHookInfoPool->_blockCif), impForBlock(block), ret, innerArgs);
  } else {
    // original IMP
    ffi_call(cif, (void (*)(void))isaClassHookInfoPool.originalIMP, ret, args);
  }
  // after hooks
  ffi_call_infos(originalClassHookInfoPool.afterInfos);
  ffi_call_infos(instanceHookInfoPool.afterInfos);
  free(innerArgs);
}

@end
