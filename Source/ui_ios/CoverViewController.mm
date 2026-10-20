#import <SDWebImage/UIImageView+WebCache.h>
#import "CoverViewController.h"
#import "EmulatorViewController.h"
#import "SettingsViewController.h"
#import "../ui_shared/BootablesProcesses.h"
#import "../ui_shared/BootablesDbClient.h"
#import "PathUtils.h"
#import "BackgroundLayer.h"
#import "CoverViewCell.h"
#import "AltServerJitService.h"

#include <sys/types.h>
#include <unistd.h>
#include <algorithm>

extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);
#define PLAY_CS_OPS_STATUS 0
#define PLAY_CS_DEBUGGED 0x10000000

static bool IsJitAvailable()
{
	//CS_DEBUGGED is set when a debugger is attached (StikJIT, SideStore, JitStreamer, Xcode, etc.)
	{
		int flags = 0;
		if(csops(getpid(), PLAY_CS_OPS_STATUS, &flags, sizeof(flags)) == 0 && (flags & PLAY_CS_DEBUGGED))
		{
			return true;
		}
	}
	//If ppid != 1, it means we're being run in the debugger
	if(getppid() != 1) return true;
	if([[AltServerJitService sharedAltServerJitService] jitEnabled])
	{
		return true;
	}
	{
		//Check if we can scan the mobile directory (only possible if jailbroken)
		std::error_code errorCode;
		fs::directory_iterator dirIterator("/private/var/mobile", errorCode);
		if(!errorCode)
		{
			return true;
		}
	}
	return false;
}

@interface CoverViewController () <UIDocumentPickerDelegate, UISearchResultsUpdating>
{
	BootableArray _visible;
	NSString* _query;
	UILabel* _emptyLabel;
	NSTimer* _jitTimer;
}
@end

@implementation CoverViewController

static NSString* const reuseIdentifier = @"coverCell";

- (void)buildCollectionWithForcedFullScan:(BOOL)forceFullDeviceScan
{
	UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Building collection" message:@"Please wait..." preferredStyle:UIAlertControllerStyleAlert];

	CGRect aivRect = CGRectMake(0, 0, 40, 40);

	UIActivityIndicatorView* aiv = [[UIActivityIndicatorView alloc] initWithFrame:aivRect];
	[aiv startAnimating];

	UIViewController* vc = [[UIViewController alloc] init];
	vc.preferredContentSize = aivRect.size;
	[vc.view addSubview:aiv];
	[alert setValue:vc forKey:@"contentViewController"];

	[self presentViewController:alert animated:YES completion:nil];

	dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
	dispatch_async(queue, ^{
	  auto activeDirs = GetActiveBootableDirectories();
	  if(forceFullDeviceScan)
	  {
		  dispatch_async(dispatch_get_main_queue(), ^{
			alert.message = @"Scanning games on filesystem...";
		  });
		  ScanBootables("/private/var/mobile");
	  }
	  else if(!activeDirs.empty())
	  {
		  dispatch_async(dispatch_get_main_queue(), ^{
			alert.message = @"Scanning games in active directories...";
		  });
		  for(const auto& activeDir : activeDirs)
		  {
			  ScanBootables(activeDir, false);
		  }
	  }

	  //Always scan games in app storage. The app's path change when it's reinstalled,
	  //thus, games from the previous installation won't be found (will be deleted in PurgeInexistingFiles).
	  dispatch_async(dispatch_get_main_queue(), ^{
		alert.message = @"Scanning games in app storage...";
	  });
	  ScanBootables(Framework::PathUtils::GetPersonalDataPath());

	  dispatch_async(dispatch_get_main_queue(), ^{
		alert.message = @"Purging inexisting files...";
	  });
	  PurgeInexistingFiles();

	  dispatch_async(dispatch_get_main_queue(), ^{
		alert.message = @"Fetching game titles...";
	  });
	  FetchGameTitles();

	  if(_bootables)
	  {
		  delete _bootables;
		  _bootables = nullptr;
	  }
	  _bootables = new BootableArray(BootablesDb::CClient::GetInstance().GetBootables());

	  //Done
	  dispatch_async(dispatch_get_main_queue(), ^{
		[alert dismissViewControllerAnimated:YES completion:nil];
		[self applyFilter];
	  });
	});
}

//Rebuilds the list of visible games (search filter + most recently played first)
- (void)applyFilter
{
	_visible.clear();
	if(_bootables)
	{
		NSString* query = [_query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		for(const auto& bootable : *_bootables)
		{
			if(query.length != 0)
			{
				NSString* title = [NSString stringWithUTF8String:bootable.title.c_str()];
				if(title == nil || [title rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound)
				{
					continue;
				}
			}
			_visible.push_back(bootable);
		}
		std::stable_sort(_visible.begin(), _visible.end(),
		                 [](const BootablesDb::Bootable& a, const BootablesDb::Bootable& b) {
			                 return a.lastBootedTime > b.lastBootedTime;
		                 });
	}
	if(_emptyLabel)
	{
		_emptyLabel.hidden = !_visible.empty();
		_emptyLabel.text = (_query.length != 0) ? @"لا توجد نتائج" : @"لا توجد ألعاب بعد\n\nاضغط على + لإضافة لعبة\n(ISO / BIN / CHD)";
	}
	[self.collectionView reloadData];
}

- (void)updateJitStatus
{
	if(IsJitAvailable())
	{
		self.navigationItem.prompt = @"JIT: شغّال ✅";
	}
	else
	{
		self.navigationItem.prompt = @"JIT: غير مفعّل ⚠️ (فعّله قبل تشغيل اللعبة)";
	}
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	[self updateJitStatus];
	[_jitTimer invalidate];
	_jitTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
	                                             target:self
	                                           selector:@selector(updateJitStatus)
	                                           userInfo:nil
	                                            repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated
{
	[_jitTimer invalidate];
	_jitTimer = nil;
	[super viewWillDisappear:animated];
}

#pragma mark Adding games

- (void)onAddGames:(id)sender
{
	UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.data" ] inMode:UIDocumentPickerModeImport];
	picker.delegate = self;
	picker.allowsMultipleSelection = YES;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls
{
	NSString* destDir = [NSString stringWithUTF8String:Framework::PathUtils::GetPersonalDataPath().native().c_str()];
	NSFileManager* fm = [NSFileManager defaultManager];
	NSMutableArray<NSString*>* failed = [NSMutableArray array];
	for(NSURL* url in urls)
	{
		NSString* dest = [destDir stringByAppendingPathComponent:url.lastPathComponent];
		[fm removeItemAtPath:dest error:nil];
		NSError* error = nil;
		if(![fm moveItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:&error] &&
		   ![fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:&error])
		{
			[failed addObject:url.lastPathComponent];
		}
	}
	if(failed.count != 0)
	{
		NSLog(@"Failed to import: %@", [failed componentsJoinedByString:@", "]);
	}
	dispatch_async(dispatch_get_main_queue(), ^{
	  [self buildCollectionWithForcedFullScan:NO];
	});
}

#pragma mark Search

- (void)updateSearchResultsForSearchController:(UISearchController*)searchController
{
	_query = searchController.searchBar.text;
	[self applyFilter];
}

- (void)viewDidLoad
{
	[super viewDidLoad];

	CAGradientLayer* bgLayer = [BackgroundLayer darkGradient];
	bgLayer.frame = self.view.bounds;
	[self.view.layer insertSublayer:bgLayer atIndex:0];

	//Dark theme + titles
	if(@available(iOS 13.0, *))
	{
		self.navigationController.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
	}
	self.title = @"الألعاب";
	self.navigationItem.title = @"الألعاب";
	if(self.navigationItem.leftBarButtonItem)
	{
		self.navigationItem.leftBarButtonItem.title = @"خروج";
	}
	UIBarButtonItem* settingsItem = self.navigationItem.rightBarButtonItem;
	settingsItem.title = @"الإعدادات";
	UIBarButtonItem* addItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(onAddGames:)];
	self.navigationItem.rightBarButtonItems = settingsItem ? @[ settingsItem, addItem ] : @[ addItem ];

	//Search
	UISearchController* searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
	searchController.searchResultsUpdater = self;
	searchController.obscuresBackgroundDuringPresentation = NO;
	searchController.searchBar.placeholder = @"ابحث عن لعبة";
	self.navigationItem.searchController = searchController;
	self.navigationItem.hidesSearchBarWhenScrolling = NO;
	self.definesPresentationContext = YES;

	//Empty state
	_emptyLabel = [[UILabel alloc] init];
	_emptyLabel.textAlignment = NSTextAlignmentCenter;
	_emptyLabel.numberOfLines = 0;
	_emptyLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
	_emptyLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
	_emptyLabel.hidden = YES;
	self.collectionView.backgroundView = _emptyLabel;

	self.collectionView.allowsMultipleSelection = NO;
	if(@available(iOS 11.0, *))
	{
		self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
	}

	[[AltServerJitService sharedAltServerJitService] startProcess];
	[self buildCollectionWithForcedFullScan:NO];
}

- (void)viewDidUnload
{
	assert(_bootables != nullptr);
	delete _bootables;

	[super viewDidUnload];
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
	// resize your layers based on the view’s new bounds
	[[[self.view.layer sublayers] objectAtIndex:0] setFrame:self.view.bounds];
}

- (BOOL)shouldAutorotate
{
	if([self isViewLoaded] && self.view.window)
	{
		return YES;
	}
	else
	{
		return NO;
	}
}

#pragma mark <UICollectionViewDataSource>

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView*)collectionView
{
	return 1;
}

- (NSString*)collectionView:(UICollectionView*)collectionView titleForHeaderInSection:(NSInteger)section
{
	return @"";
}

- (NSInteger)collectionView:(UICollectionView*)collectionView numberOfItemsInSection:(NSInteger)section
{
	return _visible.size();
}

- (UICollectionViewCell*)collectionView:(UICollectionView*)collectionView cellForItemAtIndexPath:(NSIndexPath*)indexPath
{
	CoverViewCell* cell = (CoverViewCell*)[collectionView dequeueReusableCellWithReuseIdentifier:reuseIdentifier forIndexPath:indexPath];

	auto bootable = _visible[indexPath.row];
	UIImage* placeholder = [UIImage imageNamed:@"boxart.png"];
	cell.nameLabel.text = [NSString stringWithUTF8String:bootable.title.c_str()];
	cell.backgroundView = [[UIImageView alloc] initWithImage:placeholder];
	cell.backgroundView.contentMode = UIViewContentModeScaleAspectFill;
	cell.backgroundView.clipsToBounds = YES;
	cell.layer.cornerRadius = 12;
	cell.layer.masksToBounds = YES;

	if(!bootable.coverUrl.empty())
	{
		NSString* coverUrl = [NSString stringWithUTF8String:bootable.coverUrl.c_str()];
		[(UIImageView*)cell.backgroundView sd_setImageWithURL:[NSURL URLWithString:coverUrl] placeholderImage:placeholder];
	}

	return cell;
}

#pragma mark <UICollectionViewDelegate>

- (BOOL)shouldPerformSegueWithIdentifier:(NSString*)identifier sender:(id)sender
{
	if([identifier isEqualToString:@"showEmulator"] && !IsJitAvailable())
	{
		UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"JIT غير مفعّل" message:@"بدون JIT راح تكون اللعبة بطيئة جداً أو يقفل التطبيق. فعّل JIT عن طريق StikJIT أو SideStore أو JitStreamer ثم ارجع. تبي تكمل؟" preferredStyle:UIAlertControllerStyleAlert];
		{
			UIAlertAction* continueAction = [UIAlertAction
			    actionWithTitle:@"كمّل"
			              style:UIAlertActionStyleDefault
			            handler:^(UIAlertAction*) {
				          [self performSegueWithIdentifier:@"showEmulator" sender:sender];
			            }];
			[alert addAction:continueAction];
		}
		{
			UIAlertAction* cancelAction = [UIAlertAction
			    actionWithTitle:@"إلغاء"
			              style:UIAlertActionStyleCancel
			            handler:^(UIAlertAction*){}];
			[alert addAction:cancelAction];
		}
		{
			UIAlertAction* helpAction = [UIAlertAction
			    actionWithTitle:@"مساعدة"
			              style:UIAlertActionStyleDefault
			            handler:^(UIAlertAction*) {
				          [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/jpd002/Play-#running-on-ios"]];
			            }];
			[alert addAction:helpAction];
		}
		[self presentViewController:alert animated:YES completion:nil];
		return NO;
	}
	return YES;
}

- (void)prepareForSegue:(UIStoryboardSegue*)segue sender:(id)sender
{
	if([segue.identifier isEqualToString:@"showEmulator"])
	{
		NSIndexPath* indexPath = [[self.collectionView indexPathsForSelectedItems] objectAtIndex:0];
		auto bootable = _visible[indexPath.row];
		BootablesDb::CClient::GetInstance().SetLastBootedTime(bootable.path, time(nullptr));
		EmulatorViewController* emulatorViewController = segue.destinationViewController;
		emulatorViewController.bootablePath = [NSString stringWithUTF8String:bootable.path.native().c_str()];
		[self.collectionView deselectItemAtIndexPath:indexPath animated:NO];
	}
	else if([segue.identifier isEqualToString:@"showSettings"])
	{
		UINavigationController* navViewController = segue.destinationViewController;
		if(@available(iOS 13.0, *))
		{
			navViewController.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
		}
		SettingsViewController* settingsViewController = (SettingsViewController*)navViewController.visibleViewController;
		settingsViewController.allowFullDeviceScan = true;
		settingsViewController.allowGsHandlerSelection = true;
		settingsViewController.completionHandler = ^(bool fullScanRequested) {
		  [[AltServerJitService sharedAltServerJitService] startProcess];
		  if(fullScanRequested)
		  {
			  [self buildCollectionWithForcedFullScan:YES];
		  }
		};
	}
}

- (IBAction)onExit:(id)sender
{
	exit(0);
}

@end
