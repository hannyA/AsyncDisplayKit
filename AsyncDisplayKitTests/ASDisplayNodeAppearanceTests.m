/* Copyright (c) 2014-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import <objc/runtime.h>

#import <UIKit/UIKit.h>

#import <XCTest/XCTest.h>

#import "_ASDisplayView.h"
#import "ASDisplayNode+Subclasses.h"
#import "ASDisplayNodeExtras.h"
#import "UIView+ASConvenience.h"

// helper functions
IMP class_replaceMethodWithBlock(Class class, SEL originalSelector, id block);
IMP class_replaceMethodWithBlock(Class class, SEL originalSelector, id block)
{
  IMP newImplementation = imp_implementationWithBlock(block);
  Method method = class_getInstanceMethod(class, originalSelector);
  return class_replaceMethod(class, originalSelector, newImplementation, method_getTypeEncoding(method));
}

static dispatch_block_t modifyMethodByAddingPrologueBlockAndReturnCleanupBlock(Class class, SEL originalSelector, id block);
static dispatch_block_t modifyMethodByAddingPrologueBlockAndReturnCleanupBlock(Class class, SEL originalSelector, id block)
{
  __block IMP originalImp = NULL;
  void (^blockCopied)(id) = [block copy];
  void (^blockActualSwizzle)(id) = [^(id swizzedSelf){
    blockCopied(swizzedSelf);
    originalImp(swizzedSelf, originalSelector);
  } copy];
  originalImp = class_replaceMethodWithBlock(class, originalSelector, blockActualSwizzle);
  void (^cleanupBlock)(void) = ^{
    // restore original method
    Method method = class_getInstanceMethod(class, originalSelector);
    class_replaceMethod(class, originalSelector, originalImp, method_getTypeEncoding(method));
    // release copied blocks
    [blockCopied release];
    [blockActualSwizzle release];
  };
  return [[cleanupBlock copy] autorelease];
}

@interface ASDisplayNode (PrivateStuffSoWeDontPullInCPPInternalH)
- (BOOL)__visibilityNotificationsDisabled;
@end

@interface ASDisplayNodeAppearanceTests : XCTestCase
@end

#define DeclareNodeNamed(n) ASDisplayNode *n = [[ASDisplayNode alloc] init]; n.name = @#n
#define DeclareViewNamed(v) UIView *v = [[UIView alloc] init]; v.layer.asyncdisplaykit_name = @#v
#define DeclareLayerNamed(l) CALayer *l = [[CALayer alloc] init]; l.asyncdisplaykit_name = @#l

@implementation ASDisplayNodeAppearanceTests
{
  _ASDisplayView *_view;

  NSMutableArray *_swizzleCleanupBlocks;

  NSCountedSet *_willAppearCounts;
  NSCountedSet *_willDisappearCounts;
  NSCountedSet *_didDisappearCounts;

}

- (void)setUp
{
  [super setUp];

  _swizzleCleanupBlocks = [[NSMutableArray alloc] init];

  // Using this instead of mocks. Count # of times method called
  _willAppearCounts = [[NSCountedSet alloc] init];
  _willDisappearCounts = [[NSCountedSet alloc] init];
  _didDisappearCounts = [[NSCountedSet alloc] init];

  dispatch_block_t cleanupBlock = modifyMethodByAddingPrologueBlockAndReturnCleanupBlock([ASDisplayNode class], @selector(willAppear), ^(id blockSelf){
    [_willAppearCounts addObject:blockSelf];
  });
  [_swizzleCleanupBlocks addObject:cleanupBlock];
  cleanupBlock = modifyMethodByAddingPrologueBlockAndReturnCleanupBlock([ASDisplayNode class], @selector(didDisappear), ^(id blockSelf){
    [_didDisappearCounts addObject:blockSelf];
  });
  [_swizzleCleanupBlocks addObject:cleanupBlock];
  cleanupBlock = modifyMethodByAddingPrologueBlockAndReturnCleanupBlock([ASDisplayNode class], @selector(willDisappear), ^(id blockSelf){
    [_willDisappearCounts addObject:blockSelf];
  });
  [_swizzleCleanupBlocks addObject:cleanupBlock];
}

- (void)tearDown
{
  [super tearDown];

  for(id cleanupBlock in _swizzleCleanupBlocks) {
    void (^cleanupBlockCasted)(void) = cleanupBlock;
    cleanupBlockCasted();
  }
  [_swizzleCleanupBlocks release];
  _swizzleCleanupBlocks = nil;

  [_willAppearCounts release];
  _willAppearCounts = nil;
  [_willDisappearCounts release];
  _willDisappearCounts = nil;
  [_didDisappearCounts release];
  _didDisappearCounts = nil;
}

- (void)testAppearanceMethodsCalledWithRootNodeInWindowLayer
{
  [self checkAppearanceMethodsCalledWithRootNodeInWindowLayerBacked:YES];
}

- (void)testAppearanceMethodsCalledWithRootNodeInWindowView
{
  [self checkAppearanceMethodsCalledWithRootNodeInWindowLayerBacked:NO];
}

- (void)checkAppearanceMethodsCalledWithRootNodeInWindowLayerBacked:(BOOL)isLayerBacked
{
  // ASDisplayNode visibility does not change if modifying a hierarchy that is not in a window.  So create one and add the superview to it.
  UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectZero];

  DeclareNodeNamed(n);
  DeclareViewNamed(superview);

  n.isLayerBacked = isLayerBacked;

  if (isLayerBacked) {
    [superview.layer addSublayer:n.layer];
  } else {
    [superview addSubview:n.view];
  }

  XCTAssertEqual([_willAppearCounts countForObject:n], 0u, @"willAppear erroneously called");
  XCTAssertEqual([_willDisappearCounts countForObject:n], 0u, @"willDisppear erroneously called");
  XCTAssertEqual([_didDisappearCounts countForObject:n], 0u, @"didDisappear erroneously called");

  [window addSubview:superview];
  XCTAssertEqual([_willAppearCounts countForObject:n], 1u, @"willAppear not called when node's view added to hierarchy");
  XCTAssertEqual([_willDisappearCounts countForObject:n], 0u, @"willDisppear erroneously called");
  XCTAssertEqual([_didDisappearCounts countForObject:n], 0u, @"didDisappear erroneously called");

  XCTAssertTrue(n.inWindow, @"Node should be visible");

  if (isLayerBacked) {
    [n.layer removeFromSuperlayer];
  } else {
    [n.view removeFromSuperview];
  }

  XCTAssertFalse(n.inWindow, @"Node should be not visible");

  XCTAssertEqual([_willAppearCounts countForObject:n], 1u, @"willAppear not called when node's view added to hierarchy");
  XCTAssertEqual([_willDisappearCounts countForObject:n], 1u, @"willDisppear erroneously called");
  XCTAssertEqual([_didDisappearCounts countForObject:n], 1u, @"didDisappear erroneously called");

  [superview release];
  [window release];
}

- (void)checkManualAppearanceViewLoaded:(BOOL)isViewLoaded layerBacked:(BOOL)isLayerBacked
{
  // ASDisplayNode visibility does not change if modifying a hierarchy that is not in a window.  So create one and add the superview to it.
  UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectZero];

  DeclareNodeNamed(parent);
  DeclareNodeNamed(a);
  DeclareNodeNamed(b);
  DeclareNodeNamed(aa);
  DeclareNodeNamed(ab);

  for (ASDisplayNode *n in @[parent, a, b, aa, ab]) {
    n.isLayerBacked = isLayerBacked;
    if (isViewLoaded)
      [n layer];
  }

  [parent addSubnode:a];

  XCTAssertFalse(parent.inWindow, @"Nothing should be visible");
  XCTAssertFalse(a.inWindow, @"Nothing should be visible");
  XCTAssertFalse(b.inWindow, @"Nothing should be visible");
  XCTAssertFalse(aa.inWindow, @"Nothing should be visible");
  XCTAssertFalse(ab.inWindow, @"Nothing should be visible");

  if (isLayerBacked) {
    [window.layer addSublayer:parent.layer];
  } else {
    [window addSubview:parent.view];
  }

  XCTAssertEqual([_willAppearCounts countForObject:parent], 1u, @"Should have -willAppear called once");
  XCTAssertEqual([_willAppearCounts countForObject:a], 1u, @"Should have -willAppear called once");
  XCTAssertEqual([_willAppearCounts countForObject:b], 0u, @"Should not have appeared yet");
  XCTAssertEqual([_willAppearCounts countForObject:aa], 0u, @"Should not have appeared yet");
  XCTAssertEqual([_willAppearCounts countForObject:ab], 0u, @"Should not have appeared yet");

  XCTAssertTrue(parent.inWindow, @"Should be visible");
  XCTAssertTrue(a.inWindow, @"Should be visible");
  XCTAssertFalse(b.inWindow, @"Nothing should be visible");
  XCTAssertFalse(aa.inWindow, @"Nothing should be visible");
  XCTAssertFalse(ab.inWindow, @"Nothing should be visible");

  // Add to an already-visible node should make the node visible
  [parent addSubnode:b];
  [a insertSubnode:aa atIndex:0];
  [a insertSubnode:ab aboveSubnode:aa];

  XCTAssertTrue(parent.inWindow, @"Should be visible");
  XCTAssertTrue(a.inWindow, @"Should be visible");
  XCTAssertTrue(b.inWindow, @"Should be visible after adding to visible parent");
  XCTAssertTrue(aa.inWindow, @"Nothing should be visible");
  XCTAssertTrue(ab.inWindow, @"Nothing should be visible");

  XCTAssertEqual([_willAppearCounts countForObject:parent], 1u, @"Should have -willAppear called once");
  XCTAssertEqual([_willAppearCounts countForObject:a], 1u, @"Should have -willAppear called once");
  XCTAssertEqual([_willAppearCounts countForObject:b], 1u, @"Should have -willAppear called once");
  XCTAssertEqual([_willAppearCounts countForObject:aa], 1u, @"Should have -willAppear called once");
  XCTAssertEqual([_willAppearCounts countForObject:ab], 1u, @"Should have -willAppear called once");

  if (isLayerBacked) {
    [parent.layer removeFromSuperlayer];
  } else {
    [parent.view removeFromSuperview];
  }

  XCTAssertEqual([_willDisappearCounts countForObject:parent], 1u, @"Should disappear properly");
  XCTAssertEqual([_willDisappearCounts countForObject:a], 1u, @"Should disappear properly");
  XCTAssertEqual([_willDisappearCounts countForObject:b], 1u, @"Should disappear properly");
  XCTAssertEqual([_willDisappearCounts countForObject:aa], 1u, @"Should disappear properly");
  XCTAssertEqual([_willDisappearCounts countForObject:ab], 1u, @"Should disappear properly");

  XCTAssertFalse(parent.inWindow, @"Nothing should be visible");
  XCTAssertFalse(a.inWindow, @"Nothing should be visible");
  XCTAssertFalse(b.inWindow, @"Nothing should be visible");
  XCTAssertFalse(aa.inWindow, @"Nothing should be visible");
  XCTAssertFalse(ab.inWindow, @"Nothing should be visible");
}

- (void)testAppearanceMethodsNoLayer
{
  [self checkManualAppearanceViewLoaded:NO layerBacked:YES];
}

- (void)testAppearanceMethodsNoView
{
  [self checkManualAppearanceViewLoaded:NO layerBacked:NO];
}

- (void)testAppearanceMethodsLayer
{
  [self checkManualAppearanceViewLoaded:YES layerBacked:YES];
}

- (void)testAppearanceMethodsView
{
  [self checkManualAppearanceViewLoaded:YES layerBacked:NO];
}

- (void)testSynchronousIntermediaryView
{
  // Parent is a wrapper node for a scrollview
  ASDisplayNode *parentSynchronousNode = [[ASDisplayNode alloc] initWithViewClass:[UIScrollView class]];
  DeclareNodeNamed(layerBackedNode);
  DeclareNodeNamed(viewBackedNode);

  layerBackedNode.isLayerBacked = YES;

  UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectZero];
  [parentSynchronousNode addSubnode:layerBackedNode];
  [parentSynchronousNode addSubnode:viewBackedNode];

  XCTAssertFalse(parentSynchronousNode.inWindow, @"Should not yet be visible");
  XCTAssertFalse(layerBackedNode.inWindow, @"Should not yet be visible");
  XCTAssertFalse(viewBackedNode.inWindow, @"Should not yet be visible");

  [window addSubview:parentSynchronousNode.view];

  // This is a known case that isn't supported
  XCTAssertFalse(parentSynchronousNode.inWindow, @"Synchronous views are not currently marked visible");

  XCTAssertTrue(layerBackedNode.inWindow, @"Synchronous views' subviews should get marked visible");
  XCTAssertTrue(viewBackedNode.inWindow, @"Synchronous views' subviews should get marked visible");

  // Try moving a node to/from a synchronous node in the window with the node API
  // Setup
  [layerBackedNode removeFromSupernode];
  [viewBackedNode removeFromSupernode];
  XCTAssertFalse(layerBackedNode.inWindow, @"aoeu");
  XCTAssertFalse(viewBackedNode.inWindow, @"aoeu");

  // now move to synchronous node
  [parentSynchronousNode addSubnode:layerBackedNode];
  [parentSynchronousNode insertSubnode:viewBackedNode aboveSubnode:layerBackedNode];
  XCTAssertTrue(layerBackedNode.inWindow, @"Synchronous views' subviews should get marked visible");
  XCTAssertTrue(viewBackedNode.inWindow, @"Synchronous views' subviews should get marked visible");

  [parentSynchronousNode.view removeFromSuperview];

  XCTAssertFalse(parentSynchronousNode.inWindow, @"Should not have changed");
  XCTAssertFalse(layerBackedNode.inWindow, @"Should have been marked invisible when synchronous superview was removed from the window");
  XCTAssertFalse(viewBackedNode.inWindow, @"Should have been marked invisible when synchronous superview was removed from the window");

  [window release];
  [parentSynchronousNode release];
  [layerBackedNode release];
  [viewBackedNode release];
}

- (void)checkMoveAcrossHierarchyLayerBacked:(BOOL)isLayerBacked useManualCalls:(BOOL)useManualDisable useNodeAPI:(BOOL)useNodeAPI
{
  UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectZero];

  DeclareNodeNamed(parentA);
  DeclareNodeNamed(parentB);
  DeclareNodeNamed(child);
  DeclareNodeNamed(childSubnode);

  for (ASDisplayNode *n in @[parentA, parentB, child, childSubnode]) {
    n.isLayerBacked = isLayerBacked;
  }

  [parentA addSubnode:child];
  [child addSubnode:childSubnode];

  XCTAssertFalse(parentA.inWindow, @"Should not yet be visible");
  XCTAssertFalse(parentB.inWindow, @"Should not yet be visible");
  XCTAssertFalse(child.inWindow, @"Should not yet be visible");
  XCTAssertFalse(childSubnode.inWindow, @"Should not yet be visible");
  XCTAssertFalse(childSubnode.inWindow, @"Should not yet be visible");

  XCTAssertEqual([_willAppearCounts countForObject:child], 0u, @"Should not have -willAppear called");
  XCTAssertEqual([_willAppearCounts countForObject:childSubnode], 0u, @"Should not have -willAppear called");

  if (isLayerBacked) {
    [window.layer addSublayer:parentA.layer];
    [window.layer addSublayer:parentB.layer];
  } else {
    [window addSubview:parentA.view];
    [window addSubview:parentB.view];
  }

  XCTAssertTrue(parentA.inWindow, @"Should be visible after added to window");
  XCTAssertTrue(parentB.inWindow, @"Should be visible after added to window");
  XCTAssertTrue(child.inWindow, @"Should be visible after parent added to window");
  XCTAssertTrue(childSubnode.inWindow, @"Should be visible after parent added to window");

  XCTAssertEqual([_willAppearCounts countForObject:child], 1u, @"Should have -willAppear called once");
  XCTAssertEqual([_willAppearCounts countForObject:childSubnode], 1u, @"Should have -willAppear called once");

  // Move subnode from A to B
  if (useManualDisable) {
    ASDisplayNodeDisableHierarchyNotifications(child);
  }
  if (!useNodeAPI) {
    [child removeFromSupernode];
    [parentB addSubnode:child];
  } else {
    [parentB addSubnode:child];
  }
  if (useManualDisable) {
    XCTAssertTrue([child __visibilityNotificationsDisabled], @"Should not have re-enabled yet");
    ASDisplayNodeEnableHierarchyNotifications(child);
  }

  XCTAssertEqual([_willAppearCounts countForObject:child], 1u, @"Should not have -willAppear called when moving child around in hierarchy");
  XCTAssertEqual([_willDisappearCounts countForObject:child], 0u, @"Should not have -willDisappear called when moving child around in hierarchy");
  XCTAssertEqual([_willDisappearCounts countForObject:childSubnode], 0u, @"Subnode should not have -willDisappear called when moving parent (child) around in hierarchy");

  // Move subnode back to A
  if (useManualDisable) {
    ASDisplayNodeDisableHierarchyNotifications(child);
  }
  if (!useNodeAPI) {
    [child removeFromSupernode];
    [parentA insertSubnode:child atIndex:0];
  } else {
    [parentA insertSubnode:child atIndex:0];
  }
  if (useManualDisable) {
    XCTAssertTrue([child __visibilityNotificationsDisabled], @"Should not have re-enabled yet");
    ASDisplayNodeEnableHierarchyNotifications(child);
  }


  XCTAssertEqual([_willAppearCounts countForObject:child], 1u, @"Should not have -willAppear called when moving child around in hierarchy");
  XCTAssertEqual([_willDisappearCounts countForObject:child], 0u, @"Should not have -willDisappear called when moving child around in hierarchy");

  // Finally, remove subnode
  [child removeFromSupernode];

  XCTAssertEqual([_willAppearCounts countForObject:child], 1u, @"Should appear and disappear just once");
  XCTAssertEqual([_willDisappearCounts countForObject:child], 1u, @"Should appear and disappear just once");
  XCTAssertEqual([_willDisappearCounts countForObject:childSubnode], 1u, @"Should appear and disappear just once");

  // Make sure that we don't leave these unbalanced
  XCTAssertFalse([child __visibilityNotificationsDisabled], @"Unbalanced visibility notifications calls");

  [window release];
}

- (void)testMoveAcrossHierarchyLayer
{
  [self checkMoveAcrossHierarchyLayerBacked:YES useManualCalls:NO useNodeAPI:YES];
}

- (void)testMoveAcrossHierarchyView
{
  [self checkMoveAcrossHierarchyLayerBacked:NO useManualCalls:NO useNodeAPI:YES];
}

- (void)testMoveAcrossHierarchyManualLayer
{
  [self checkMoveAcrossHierarchyLayerBacked:YES useManualCalls:YES useNodeAPI:NO];
}

- (void)testMoveAcrossHierarchyManualView
{
  [self checkMoveAcrossHierarchyLayerBacked:NO useManualCalls:YES useNodeAPI:NO];
}

- (void)testDisableWithNodeAPILayer
{
  [self checkMoveAcrossHierarchyLayerBacked:YES useManualCalls:YES useNodeAPI:YES];
}

- (void)testDisableWithNodeAPIView
{
  [self checkMoveAcrossHierarchyLayerBacked:NO useManualCalls:YES useNodeAPI:YES];
}

- (void)testPreventManualAppearanceMethods
{
  DeclareNodeNamed(n);

  XCTAssertThrows([n willAppear], @"Should not allow manually calling appearance methods.");
  XCTAssertThrows([n willDisappear], @"Should not allow manually calling appearance methods.");
  XCTAssertThrows([n didDisappear], @"Should not allow manually calling appearance methods.");
}

@end
