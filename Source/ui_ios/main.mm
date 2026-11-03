#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#include "DebuggerSimulator.h"
#include "DefaultAppConfig.h"

int main(int argc, char* argv[])
{
	//The old self-ptrace trick never gives JIT on modern iOS and it blocks
	//StikDebug from attaching later, so only use it on old systems.
	if(@available(iOS 17.0, *))
	{
	}
	else
	{
		StartSimulateDebugger();
	}
	@autoreleasepool
	{
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
	}
}
