#import "Themes.h"

// Get current theme mode from NSUserDefaults (0 = dark, 1 = light)
int getMode() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSNumber *mode = [defaults objectForKey:@"theme_mode"];
    return mode ? [mode intValue] : 0; // default to dark
}

NSDictionary* getCurrentTheme() {
   	NSFileManager *fileManager = [NSFileManager defaultManager];
   if (![fileManager fileExistsAtPath:CURRENT_THEME]) {
       BunnyLog(@"Theme file does not exist at: %@", CURRENT_THEME);
       return nil;
   }

   NSError *readError = nil;
   NSData *jsonData = [NSData dataWithContentsOfFile:CURRENT_THEME options:0 error:&readError];
   if (readError) {
       BunnyLog(@"Failed to read theme file: %@", readError);
       return nil;
   }

   NSError *jsonError = nil;
   NSDictionary *themeDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];
   if (jsonError) {
       BunnyLog(@"Failed to parse theme JSON: %@", jsonError);
       return nil;
   }

   BunnyLog(@"Theme loaded: %@", themeDict);
   return [themeDict copy];
}



// Returns a dictionary of semantic color names -> hex strings for the current mode
NSDictionary* getSemantic() {
    NSDictionary *theme = getCurrentTheme();
    if (!theme) {
        BunnyLog(@"No theme loaded");
        return nil;
    }

    NSDictionary *data = theme[@"data"];
    if (![data isKindOfClass:[NSDictionary class]]) {
        BunnyLog(@"Invalid theme data");
        return nil;
    }

    NSNumber *spec = data[@"spec"];
    NSDictionary *semanticSource = nil;

    if ([spec intValue] == 3 || !spec) {
        semanticSource = theme[@"main"][@"semantic"];
    } else if ([spec intValue] == 2) {
        semanticSource = data[@"semanticColors"];
    } else if ([spec intValue] == 1 || !spec) {
        semanticSource = data[@"theme_color_map"];
    } else {
        BunnyLog(@"Unsupported theme spec: %@", spec);
        return nil;
    }

    if (![semanticSource isKindOfClass:[NSDictionary class]]) {
        BunnyLog(@"No semantic colors found");
        return nil;
    }

    int mode = getMode(); // 0 = dark, 1 = light

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    for (NSString *key in semanticSource) {
        id value = semanticSource[key];
        if ([value isKindOfClass:[NSArray class]]) {
            NSArray *arr = (NSArray *)value;
            if (arr.count > mode) {
                NSString *colorStr = arr[mode];
                if ([colorStr isKindOfClass:[NSString class]]) {
                    result[key] = colorStr;
                }
            }
        }
    }

    return [result copy];
}

UIColor* colorFromHexString(NSString *hexString) {
	unsigned rgbValue = 0;
	NSScanner *scanner = [NSScanner scannerWithString:hexString];
	[scanner setScanLocation: 1];
	[scanner scanHexInt: &rgbValue];

	return [UIColor colorWithRed:((rgbValue & 0xFF0000) >> 16)/255.0 green:((rgbValue & 0xFF00) >> 8)/255.0 blue:(rgbValue & 0xFF)/255.0 alpha:1.0];
}

UIColor* getColor(NSString *name, NSString *kind) {
	if ([kind isEqual:@"semantic"]) {
	    NSDictionary *semanticColors = nil;
		if (!semanticColors) {
			semanticColors = getSemantic();
		}

		if (![semanticColors objectForKey:name]) {
			return NULL;
		}

		NSString *value = semanticColors[name];
		UIColor *color;

		color = colorFromHexString(value);
		return color;
	}
	return nil;
}

//Perform Black Magic
BOOL isThemeLight(UIColor *color) {
  CGFloat r, g, b;
  [color getRed:&r green:&g blue:&b alpha:NULL];
  CGFloat luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  if (luminance > 0.70) {
    return TRUE;
  }
  return FALSE;
}

@interface UIKeyboard : UIView
@end

@interface UIKeyboardDockView : UIView
@end

@interface TUIPredictionView : UIView
@end

@interface TUIEmojiSearchInputView : UIView
@end

@interface UIKBRenderConfig : NSObject
-(void)setLightKeyboard:(BOOL)light;
+(void)refreshKeyboard;
+(id)darkConfig;
+(id)defaultConfig;
+(id)defaultEmojiConfig;
+(id)lowQualityDarkConfig;
@end


%group KEYBOARD

	id originalKeyboardColor;

	%hook UIKeyboard
	- (void)didMoveToWindow {
		%orig;

		id color = getColor(@"KEYBOARD", @"semantic") ?: getColor(@"BACKGROUND_PRIMARY", @"semantic");

        [%c(UIKBRenderConfig) refreshKeyboard];

		if (originalKeyboardColor != nil && originalKeyboardColor != color) {
			originalKeyboardColor = [self backgroundColor];
		}
		if (color != nil) {
				[self setBackgroundColor:color];
			} else {
			[self setBackgroundColor:originalKeyboardColor];
		}
	}

	%end

	%hook UIKeyboardDockView

	- (void)didMoveToWindow {
		%orig;

		id color = getColor(@"KEYBOARD", @"semantic") ?: getColor(@"BACKGROUND_PRIMARY", @"semantic");
		if (originalKeyboardColor != nil && originalKeyboardColor != color) {
			originalKeyboardColor = [self backgroundColor];
		}
		if (color != nil) {
				[self setBackgroundColor:color];
			} else {
			[self setBackgroundColor:originalKeyboardColor];
		}
	}

	%end

	%hook UIKBRenderConfig

	- (void)setLightKeyboard:(BOOL)arg1 {
	    %orig(isThemeLight(getColor(@"KEYBOARD", @"semantic") ?: getColor(@"BACKGROUND_PRIMARY", @"semantic")));
    }

    %new
    +(void)refreshKeyboard {
       	[[self darkConfig] setLightKeyboard:TRUE];
    	[[self defaultConfig] setLightKeyboard:TRUE];
    	[[self defaultEmojiConfig] setLightKeyboard:TRUE];
    	[[self lowQualityDarkConfig] setLightKeyboard:TRUE];

    }

	%end

	%hook TUIPredictionView
	- (void)didMoveToWindow {
		%orig;


		id color = getColor(@"KEYBOARD", @"semantic") ?: getColor(@"BACKGROUND_PRIMARY", @"semantic");
		if (originalKeyboardColor != nil && originalKeyboardColor != color) {
			originalKeyboardColor = [self backgroundColor];
		}
		if (color != nil) {
			[self setBackgroundColor:color];

			for (UIView *subview in self.subviews) {
				[subview setBackgroundColor:color];
			}
		} else {
			[self setBackgroundColor:originalKeyboardColor];

			for (UIView *subview in self.subviews) {
				[subview setBackgroundColor:originalKeyboardColor];
			}
		}
	}
	%end

	%hook TUIEmojiSearchInputView

	- (void)didMoveToWindow {
		%orig;

		id color = getColor(@"KEYBOARD", @"semantic") ?: getColor(@"BACKGROUND_PRIMARY", @"semantic");
		if (originalKeyboardColor != nil && originalKeyboardColor != color) {
			originalKeyboardColor = [self backgroundColor];
		}
		if (color != nil) {
				[self setBackgroundColor:color];
			} else {
			[self setBackgroundColor:originalKeyboardColor];
		}
	}
	%end

%end

%ctor {

    NSBundle* bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/TextInputUI.framework"];
	if (!bundle.loaded) [bundle load];

	%init(KEYBOARD);

}
