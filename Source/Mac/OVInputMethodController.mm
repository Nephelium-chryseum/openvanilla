//
// OVInputMethodController.m
//
// Copyright (c) 2004-2012 Lukhnos Liu (lukhnos at openvanilla dot org)
// 
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
//

#import "OVInputMethodController.h"
#import "OpenVanilla.h"
#import "OVLoaderServiceImpl.h"
#import "OVCandidateServiceImpl.h"
#import "OVTextBufferImpl.h"
#import "OVPlistBackedKeyValueMapImpl.h"
#import "OVTextBufferCombinator.h"
#import "OVToolTipWindowController.h"
#import "OVModuleManager.h"
#import "OVUpdateChecker.h"
#import "OVConstants.h"

using namespace OpenVanilla;

@interface OVInputMethodController ()
{
@protected
    OVTextBufferImpl *_composingText;
    OVTextBufferImpl *_readingText;
    OVEventHandlingContext *_inputMethodContext;
    id _currentClient;
}
- (BOOL)handleOVKey:(OVKey &)key client:(id)client;
- (void)handleInputMethodChange:(NSNotification *)notification;
- (void)handleCandidateSelected:(NSNotification *)notification;
- (void)updateClientComposingBuffer:(id)sender;
- (void)changeInputMethodAction:(id)sender;
- (void)toggleTraditionalToSimplifiedChineseFilterAction:(id)sender;
- (void)toggleSimplifiedToTraditionalChineseFilterAction:(id)sender;
- (void)openUserGuideAction:(id)sender;
- (void)showAboutAction:(id)sender;
@end

@implementation OVInputMethodController
- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (_composingText) {
        delete _composingText;
    }

    if (_readingText) {
        delete _readingText;
    }

    if (_inputMethodContext) {
        delete _inputMethodContext;
    }

    [super dealloc];
}

+ (void)load
{
}

- (id)initWithServer:(IMKServer *)server delegate:(id)aDelegate client:(id)client
{
    self = [super initWithServer:server delegate:aDelegate client:client];
	if (self) {
        _composingText = new OVTextBufferImpl;
        _readingText = new OVTextBufferImpl;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleInputMethodChange:) name:OVModuleManagerDidUpdateActiveInputMethodNotification object:[OVModuleManager defaultManager]];
	}
	
	return self;
}

- (NSMenu *)menu
{
    NSMenu *menu = [[[NSMenu alloc] init] autorelease];

    NSString *activeInputMethodIdentifier = [OVModuleManager defaultManager].activeInputMethodIdentifier;
    NSArray *inputMethodIdentifiers = [[OVModuleManager defaultManager] inputMethodIdentifiers];
    for (NSString *identifier in inputMethodIdentifiers) {
        NSMenuItem *item = [[[NSMenuItem alloc] init] autorelease];
        [item setTitle:[[OVModuleManager defaultManager] localizedInputMethodName:identifier]];
        [item setRepresentedObject:identifier];
        [item setTarget:self];
        [item setAction:@selector(changeInputMethodAction:)];

        if ([activeInputMethodIdentifier isEqualToString:identifier]) {
            [item setState:NSOnState];
        }

        [menu addItem:item];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *filterItem;
    filterItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Convert Traditional Chinese to Simplified", @"") action:@selector(toggleTraditionalToSimplifiedChineseFilterAction:) keyEquivalent:@""] autorelease];
    [filterItem setState:([OVModuleManager defaultManager].traditionalToSimplifiedChineseFilterEnabled ? NSOnState : NSOffState)];
    [menu addItem:filterItem];

    filterItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Convert Simplified Chinese to Traditional", @"") action:@selector(toggleSimplifiedToTraditionalChineseFilterAction:) keyEquivalent:@""] autorelease];
    [filterItem setState:([OVModuleManager defaultManager].simplifiedToTraditionalChineseFilterEnabled ? NSOnState : NSOffState)];
    [menu addItem:filterItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *preferenceMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"OpenVanilla Preferences…", @"") action:@selector(showPreferences:) keyEquivalent:@""] autorelease];
    [menu addItem:preferenceMenuItem];

    NSMenuItem *userManualItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"User Guide", @"") action:@selector(openUserGuideAction:) keyEquivalent:@""] autorelease];
    [menu addItem:userManualItem];

    NSMenuItem *aboutMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"About OpenVanilla", @"") action:@selector(showAboutAction:) keyEquivalent:@""] autorelease];
    [menu addItem:aboutMenuItem];

    return menu;
}

#pragma mark IMKStateSetting protocol methods

- (void)activateServer:(id)client
{
    [OVModuleManager defaultManager].candidateService->resetAll();

    NSString *keyboardLayout = [[OVModuleManager defaultManager] alphanumericKeyboardLayoutForInputMethod:[OVModuleManager defaultManager].activeInputMethodIdentifier];
    [client overrideKeyboardWithKeyboardNamed:keyboardLayout];

    [[OVModuleManager defaultManager] synchronizeActiveInputMethodSettings];

    if (!_inputMethodContext && [OVModuleManager defaultManager].activeInputMethod) {
        _inputMethodContext = [OVModuleManager defaultManager].activeInputMethod->createContext();
    }

    if (_inputMethodContext) {
        _inputMethodContext->startSession([OVModuleManager defaultManager].loaderService);
    }

    _currentClient = client;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleCandidateSelected:) name:OVOneDimensionalCandidatePanelImplDidSelectCandidateNotification object:nil];

    if ([[NSUserDefaults standardUserDefaults] boolForKey:OVCheckForUpdateKey]) {
        [[OVUpdateChecker sharedInstance] checkForUpdateIfNeeded];
    }
}

- (void)deactivateServer:(id)client
{
    if (_inputMethodContext) {
        _inputMethodContext->stopSession([OVModuleManager defaultManager].loaderService);
    }

    NSAttributedString *emptyReading = [[[NSAttributedString alloc] initWithString:@""] autorelease];
    [client setMarkedText:emptyReading selectionRange:NSMakeRange(0, 0) replacementRange:NSMakeRange(NSNotFound, NSNotFound)];

    _composingText->commit();
    [self commitComposition:client];

    _composingText->clear();
    _readingText->clear();
    [OVModuleManager defaultManager].candidateService->resetAll();
    [[[OVModuleManager defaultManager].toolTipWindowController window] orderOut:self];
    [[OVModuleManager defaultManager] writeOutActiveInputMethodSettings];

    _currentClient = nil;

    [[NSNotificationCenter defaultCenter] removeObserver:self name:OVOneDimensionalCandidatePanelImplDidSelectCandidateNotification object:nil];
}

- (void)showPreferences:(id)sender
{
    // show the preferences panel, and also make the IME app itself the focus
    [super showPreferences:sender];
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
}

- (void)commitComposition:(id)sender
{
    // fix the premature commit bug in Terminal.app since OS X 10.5
    if ([[sender bundleIdentifier] isEqualToString:@"com.apple.Terminal"] && ![NSStringFromClass([sender class]) isEqualToString:@"IPMDServerClientWrapper"]) {
        [self performSelector:@selector(updateClientComposingBuffer:) withObject:_currentClient afterDelay:0.0];
        return;
    }

    if (_composingText->isCommitted()) {
        NSString *combinedText = [NSString stringWithUTF8String:_composingText->composedCommittedText().c_str()];
        NSString *filteredText = [[OVModuleManager defaultManager] filteredStringWithString:combinedText];
        [sender insertText:filteredText replacementRange:NSMakeRange(NSNotFound, NSNotFound)];
    }
}

- (BOOL)handleEvent:(NSEvent *)event client:(id)client
{
    if (_readingText->toolTipText().length() || _composingText->toolTipText().length()) {
        _readingText->clearToolTip();
        _composingText->clearToolTip();
        [[[OVModuleManager defaultManager].toolTipWindowController window] orderOut:self];
    }

    if ([event type] != NSKeyDown) {
        return NO;
    }

    NSString *chars = [event characters];
    NSUInteger cocoaModifiers = [event modifierFlags];
    unsigned short virtualKeyCode = [event keyCode];

    bool capsLock = !!(cocoaModifiers & NSAlphaShiftKeyMask);
	bool shift = !!(cocoaModifiers & NSShiftKeyMask);
	bool ctrl = !!(cocoaModifiers & NSControlKeyMask);
    bool opt = !!(cocoaModifiers & NSAlternateKeyMask);
	bool cmd = !!(cocoaModifiers & NSCommandKeyMask);
    bool numLock = false;

    static UInt32 numKeys[16] = {
        // 0,1,2,3,4,5, 6,7,8,9,.,+,-,*,/,=
        0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5b, 0x5c, 0x41, 0x45, 0x4e, 0x43, 0x4b, 0x51
    };

    for (size_t i = 0; i < 16; i++) {
        if (virtualKeyCode == numKeys[i]) {
            numLock = true;
            break;
        }
    }

    OVKey key;
    UniChar unicharCode = 0;
    if ([chars length] > 0) {
        unicharCode = [chars characterAtIndex:0];

        // map Ctrl-[A-Z] to a char code
        if (cocoaModifiers & NSControlKeyMask) {
            if (unicharCode < 27) {
                unicharCode += ('a' - 1);
            }
            else {
                switch (unicharCode) {
                    case 27:
                        unicharCode = (cocoaModifiers & NSShiftKeyMask) ? '{' : '[';
                        break;
                    case 28:
                        unicharCode = (cocoaModifiers & NSShiftKeyMask) ? '|' : '\\';
                        break;
                    case 29:
                        unicharCode = (cocoaModifiers & NSShiftKeyMask) ? '}': ']';
                        break;
                    case 31:
                        unicharCode = (cocoaModifiers & NSShiftKeyMask) ? '_' : '-';
                        break;
                }
            }
        }

        UniChar remappedKeyCode = unicharCode;

        // remap function key codes
        switch(unicharCode) {
            case NSUpArrowFunctionKey:      remappedKeyCode = (UniChar)OVKeyCode::Up; break;
            case NSDownArrowFunctionKey:    remappedKeyCode = (UniChar)OVKeyCode::Down; break;
            case NSLeftArrowFunctionKey:    remappedKeyCode = (UniChar)OVKeyCode::Left; break;
            case NSRightArrowFunctionKey:   remappedKeyCode = (UniChar)OVKeyCode::Right; break;
            case NSDeleteFunctionKey:       remappedKeyCode = (UniChar)OVKeyCode::Delete; break;
            case NSHomeFunctionKey:         remappedKeyCode = (UniChar)OVKeyCode::Home; break;
            case NSEndFunctionKey:          remappedKeyCode = (UniChar)OVKeyCode::End; break;
            case NSPageUpFunctionKey:       remappedKeyCode = (UniChar)OVKeyCode::PageUp; break;
            case NSPageDownFunctionKey:     remappedKeyCode = (UniChar)OVKeyCode::PageDown; break;
            case NSF1FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F1; break;
            case NSF2FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F2; break;
            case NSF3FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F3; break;
            case NSF4FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F4; break;
            case NSF5FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F5; break;
            case NSF6FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F6; break;
            case NSF7FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F7; break;
            case NSF8FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F8; break;
            case NSF9FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F9; break;
            case NSF10FunctionKey:          remappedKeyCode = (UniChar)OVKeyCode::F10; break;
        }

        unicharCode = remappedKeyCode;
    }

    if (unicharCode < 128) {
        key = [OVModuleManager defaultManager].loaderService->makeOVKey(unicharCode, opt, opt, ctrl, shift, cmd, capsLock, numLock);
    }
    else {
        key = [OVModuleManager defaultManager].loaderService->makeOVKey(string([chars UTF8String]), opt, opt, ctrl, shift, cmd, capsLock, numLock);
    }

    return [self handleOVKey:key client:client];
}


#pragma mark - Private methods

- (BOOL)handleOVKey:(OVKey &)key client:(id)client
{
    if (!_inputMethodContext) {
        return NO;
    }

    bool handled = false;
    bool candidatePanelFallThrough = false;

    OVOneDimensionalCandidatePanelImpl* panel = dynamic_cast<OVOneDimensionalCandidatePanelImpl*>([OVModuleManager defaultManager].candidateService->currentCandidatePanel());
    if (panel && panel->isInControl()) {
        OVOneDimensionalCandidatePanelImpl::KeyHandlerResult result = panel->handleKey(&key);
        switch (result) {
            case OVOneDimensionalCandidatePanelImpl::Handled:
            {
                return YES;
            }

            case OVOneDimensionalCandidatePanelImpl::CandidateSelected:
            {
                size_t index = panel->currentHightlightIndexInCandidateList();
                string candidate = panel->candidateList()->candidateAtIndex(index);
                handled = _inputMethodContext->candidateSelected([OVModuleManager defaultManager].candidateService, candidate, index, _readingText, _composingText, [OVModuleManager defaultManager].loaderService);
                candidatePanelFallThrough = true;
                break;
            }

            case OVOneDimensionalCandidatePanelImpl::Canceled:
            {
                _inputMethodContext->candidateCanceled([OVModuleManager defaultManager].candidateService, _readingText, _composingText, [OVModuleManager defaultManager].loaderService);
                handled = true;
                candidatePanelFallThrough = true;
                break;
            }

            case OVOneDimensionalCandidatePanelImpl::NonCandidatePanelKeyReceived:
            {
                handled = _inputMethodContext->candidateNonPanelKeyReceived([OVModuleManager defaultManager].candidateService, &key, _readingText, _composingText, [OVModuleManager defaultManager].loaderService);
                candidatePanelFallThrough = true;
                break;
            }

            case OVOneDimensionalCandidatePanelImpl::Invalid:
            {
                [OVModuleManager defaultManager].loaderService->beep();
                return YES;
            }

        }
    }

    if (!candidatePanelFallThrough) {
        handled = _inputMethodContext->handleKey(&key, _readingText, _composingText, [OVModuleManager defaultManager].candidateService, [OVModuleManager defaultManager].loaderService);
    }

    if (_composingText->isCommitted()) {
        [self commitComposition:client];
        _composingText->finishCommit();
    }

    [self updateClientComposingBuffer:client];
    return handled;
}

- (void)handleInputMethodChange:(NSNotification *)notification
{
    _composingText->clear();
    _readingText->clear();

    if (_inputMethodContext) {
        _inputMethodContext->stopSession([OVModuleManager defaultManager].loaderService);
        delete _inputMethodContext;
        _inputMethodContext = 0;
    }

    NSAttributedString *emptyReading = [[[NSAttributedString alloc] initWithString:@""] autorelease];
    [_currentClient setMarkedText:emptyReading selectionRange:NSMakeRange(0, 0) replacementRange:NSMakeRange(NSNotFound, NSNotFound)];
    _composingText->commit();
    [self commitComposition:_currentClient];
    _composingText->clear();
    _readingText->clear();
    [OVModuleManager defaultManager].candidateService->resetAll();
    [[[OVModuleManager defaultManager].toolTipWindowController window] orderOut:self];

    if (!_inputMethodContext && [OVModuleManager defaultManager].activeInputMethod) {
        _inputMethodContext = [OVModuleManager defaultManager].activeInputMethod->createContext();
    }

    if (_inputMethodContext) {
        _inputMethodContext->startSession([OVModuleManager defaultManager].loaderService);

        // update keyboard layout
        NSString *keyboardLayout = [[OVModuleManager defaultManager] alphanumericKeyboardLayoutForInputMethod:[OVModuleManager defaultManager].activeInputMethodIdentifier];
        [_currentClient overrideKeyboardWithKeyboardNamed:keyboardLayout];
    }
}

- (void)handleCandidateSelected:(NSNotification *)notification
{
    if (!_inputMethodContext) {
        return;
    }

    NSDictionary *dict = [notification userInfo];
    NSString *candidate = [dict objectForKey:OVOneDimensionalCandidatePanelImplSelectedCandidateStringKey];
    NSUInteger index = [[dict objectForKey:OVOneDimensionalCandidatePanelImplSelectedCandidateIndexKey] unsignedIntegerValue];

    OVModuleManager *manager = [OVModuleManager defaultManager];
    OVOneDimensionalCandidatePanel *panel = manager.candidateService->currentCandidatePanel();

    bool handled = _inputMethodContext->candidateSelected(manager.candidateService, string([candidate UTF8String]), (size_t)index, _readingText, _composingText, manager.loaderService);
    if (handled) {
        panel->hide();
        panel->cancelEventHandler();
    }
    else {
        manager.loaderService->beep();
        return;
    }

    if (_composingText->isCommitted()) {
        [self commitComposition:_currentClient];
        _composingText->finishCommit();
    }

    [self updateClientComposingBuffer:_currentClient];
}

- (void)updateClientComposingBuffer:(id)sender
{
    OVTextBufferCombinator combinedText(_composingText, _readingText);
    NSAttributedString *attrString = combinedText.combinedAttributedString();
    NSRange selectionRange = combinedText.selectionRange();

    if (_composingText->shouldUpdate() || _readingText->shouldUpdate()) {

        [sender setMarkedText:attrString selectionRange:selectionRange replacementRange:NSMakeRange(NSNotFound, NSNotFound)];

        _composingText->finishUpdate();
        _readingText->finishUpdate();
    }

    NSUInteger cursorIndex = selectionRange.location;
    if (cursorIndex == [attrString length] && cursorIndex) {
        cursorIndex--;
    }

    NSRect lineHeightRect = NSMakeRect(0.0, 0.0, 16.0, 16.0);
    @try {
        [sender attributesForCharacterIndex:cursorIndex lineHeightRectangle:&lineHeightRect];
    }
    @catch (NSException *exception) {
    }

    OVOneDimensionalCandidatePanelImpl *currentCandidatePanel = [OVModuleManager defaultManager].candidateService->currentCandidatePanel();

    currentCandidatePanel->setPanelOrigin(lineHeightRect.origin);
    currentCandidatePanel->updateVisibility();

    string toolTipText = _readingText->toolTipText();
    if (!toolTipText.length()) {
        toolTipText = _composingText->toolTipText();
    }

    if (toolTipText.length()) {
        NSPoint toolTipOrigin = lineHeightRect.origin;
        BOOL fromTopLeft = YES;
        if (currentCandidatePanel->isVisible()) {
            toolTipOrigin.y += lineHeightRect.size.height + 4.0f;
            fromTopLeft = NO;
        }

        [[OVModuleManager defaultManager].toolTipWindowController setToolTipText:[NSString stringWithUTF8String:toolTipText.c_str()] atOrigin:toolTipOrigin fromTopLeft:fromTopLeft];
        [[[OVModuleManager defaultManager].toolTipWindowController window] orderFront:self];
    }
}

- (void)changeInputMethodAction:(id)sender
{
    NSMenuItem *item = [sender objectForKey:kIMKCommandMenuItemName];
    if (item) {
        NSString *identifier = [item representedObject];
        [[OVModuleManager defaultManager] selectInputMethod:identifier];
    }
}

- (void)toggleTraditionalToSimplifiedChineseFilterAction:(id)sender
{
    OVModuleManager *manager = [OVModuleManager defaultManager];
    manager.traditionalToSimplifiedChineseFilterEnabled = !manager.traditionalToSimplifiedChineseFilterEnabled;
    manager.simplifiedToTraditionalChineseFilterEnabled = NO;
}

- (void)toggleSimplifiedToTraditionalChineseFilterAction:(id)sender
{
    OVModuleManager *manager = [OVModuleManager defaultManager];
    manager.simplifiedToTraditionalChineseFilterEnabled = !manager.simplifiedToTraditionalChineseFilterEnabled;
    manager.traditionalToSimplifiedChineseFilterEnabled = NO;
}

- (void)openUserGuideAction:(id)sender
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:OVUserGuideURLString]];
}

- (void)showAboutAction:(id)sender
{
    [[NSApplication sharedApplication] orderFrontStandardAboutPanel:sender];
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
}
@end