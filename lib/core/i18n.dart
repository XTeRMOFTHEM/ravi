/// EN / FA strings + direction, mirroring the web app's i18n behaviour.
/// Persian is the default language (same as the web version).

class Lang {
  final String code; // 'en' | 'fa'
  const Lang(this.code);

  bool get isFa => code == 'fa';
  bool get isRtl => isFa;
  String get label => isFa ? 'فارسی' : 'English';
}

class S {
  final Lang lang;
  const S(this.lang);

  String _t(String en, String fa) => lang.isFa ? fa : en;

  String get navChats => _t('Chats', 'چت‌ها');
  String get navMagazine => _t('Magazine', 'مجله');
  String get navSettings => _t('Settings', 'تنظیمات');
  String get navProfile => _t('Profile', 'پروفایل');
  String get catAll => _t('All', 'همه');
  String get catPersonal => _t('Personal', 'شخصی');
  String get catGroup => _t('Group', 'گروه');
  String get catChannel => _t('Channel', 'کانال');
  String get catBot => _t('Bot', 'بات');
  String get catOfficial => _t('Official', 'رسمی');
  String get searchChats => _t('Search chats', 'جستجوی چت‌ها');
  String get recentChats => _t('Recent chats', 'چت‌های اخیر');
  String get adTitle => _t('RAVI — Connect, Chat, Play', 'RAVI — ارتباط، چت، بازی');
  String get adText => _t('A simple, fast way to chat and connect with friends',
      'راهی ساده و سریع برای گفتگو و ارتباط با دوستان');
  String get adLabel => 'Ad';
  String get adAction => _t('View', 'مشاهده');

  // auth
  String get welcomeBack => _t('Welcome back', 'خوش برگشتی');
  String get loginSub => _t('Sign in to continue to RAVI', 'برای ادامه وارد RAVI شو');
  String get createAccount => _t('Create account', 'ساخت حساب کاربری');
  String get registerSub => _t('Join RAVI in a few seconds', 'در چند ثانیه به RAVI بپیوند');
  String get username => _t('Username', 'نام کاربری');
  String get usernameHint => _t('e.g. ravi_user', 'مثلاً ravi_user');
  String get password => _t('Password', 'رمز عبور');
  String get passwordHint => _t('••••••••', '••••••••');
  String get displayNameField => _t('Display name (optional)', 'نام نمایشی (اختیاری)');

  // ---- profile editing ----
  String get bioLabel => _t('Bio', 'بایو');
  String get bioHint => _t('Write a short intro about yourself…', 'یه معرفی کوتاه از خودت بنویس…');
  String get changePhoto => _t('Change photo', 'تغییر عکس');
  String get unblock => _t('Unblock', 'رفع مسدودی');
  String get noBlocked => _t('No blocked users', 'کاربر مسدودی نداری');
  String get adminLabel => _t('Admin', 'ادمین');
  String editFailed(String why) => _t('Could not save: $why', 'ذخیره نشد: $why');
  String get gender => _t('Gender', 'جنسیت');
  String get genderMale => _t('Male', 'پسر');
  String get genderFemale => _t('Female', 'دختر');
  String get genderOther => _t('Other', 'سایر');
  String get login => _t('Log in', 'ورود');
  String get register => _t('Sign up', 'ثبت‌نام');
  String get noAccount => _t("Don't have an account?", 'حساب کاربری نداری؟');
  String get haveAccount => _t('Already have an account?', 'حساب کاربری داری؟');
  String get loginFailed => _t('Wrong username or password', 'نام کاربری یا رمز عبور اشتباه است');
  String get registerFailed => _t('Registration failed — username may be taken', 'ثبت‌نام ناموفق بود — نام کاربری ممکن است تکراری باشد');
  String get bannedAccount => _t('Your account has been banned', 'حساب کاربری شما مسدود شده است');
  String get fillFields => _t('Please fill in all fields', 'همه فیلدها را پر کنید');
  String get connecting => _t('Connecting…', 'در حال اتصال…');
  String get serverUnreachable => _t("Can't reach the server. Check your connection.",
      'اتصال به سرور برقرار نشد. اینترنت را بررسی کنید.');
  String get fieldUsernameRequired => _t('Username is required', 'نام کاربری لازم است');
  String get fieldPasswordRequired => _t('Password is required', 'رمز عبور لازم است');
  String get fieldPasswordShort => _t('Password must be at least 4 characters', 'رمز عبور باید حداقل ۴ کاراکتر باشد');
  String get fieldUsernameInvalid => _t('3–20 characters: letters, numbers and _ only', '۳ تا ۲۰ کاراکتر: فقط حروف انگلیسی، عدد و _');
  String get usernameRule => _t('a-z, 0-9 and _ (3–20 chars)', 'حروف انگلیسی، عدد و _ (۳ تا ۲۰ کاراکتر)');

  // gifs
  String get gifLibraryTitle => _t('Your GIFs', 'گیف‌های تو');
  String get gifFromVideo => _t('New GIF', 'گیف جدید');
  String get gifConverting => _t('Making…', 'در حال ساخت…');
  String get gifEmptyTitle => _t('No GIFs yet', 'هنوز گیفی نداری');
  String get gifEmptySub => _t('Pick a video and RAVI turns it into a small looping GIF — or save GIFs you see in chats.',
      'یک ویدیو انتخاب کن تا به گیف کوچک تبدیل شود — یا گیف‌های داخل چت را ذخیره کن.');
  String get gifReady => _t('GIF is ready 🎉', 'گیف آماده شد 🎉');
  String gifUploadFailed(String why) => _t('Could not make GIF: $why', 'ساخت گیف نشد: $why');
  String get gifSavedToLibrary => _t('Saved to your GIFs', 'به گیف‌هایت اضافه شد');
  String get saveGif => _t('Save GIF', 'ذخیره گیف');
  String get deleteGifTitle => _t('Delete GIF?', 'حذف گیف؟');
  String get deleteGifConfirm => _t('It will be removed from your gallery. Old messages keep it.',
      'از گالری تو حذف می‌شود؛ در پیام‌های قدیمی باقی می‌ماند.');
  String get gifDeleted => _t('GIF deleted', 'گیف حذف شد');

  // chat
  String get messageHint => _t('Message…', 'پیام…');
  // v1.0.7 — edit / pin / player strings
  String get edit => _t('Edit', 'ویرایش');
  String get editMessage => _t('Edit message', 'ویرایش پیام');
  String get editedTag => _t('edited', 'ویرایش شد');
  String get messageEditFailed => _t('Could not edit the message', 'ویرایش پیام انجام نشد');
  String get pinChat => _t('Pin chat', 'سنجاق کردن چت');
  String get unpinChat => _t('Unpin chat', 'برداشتن سنجاق');
  String pinnedLimit(int n) => _t('You can pin up to $n chats', 'حداکثر می‌توانی $n چت سنجاق کنی');
  String get nowPlaying => _t('Now playing', 'در حال پخش');
  String get online => _t('online', 'آنلاین');
  String get typing => _t('typing…', 'در حال نوشتن…');
  String get connectingDots => _t('Connecting…', 'در حال اتصال…');
  // v1.0.8: membersOnline(int) replaces the old suffix getter
  String get membersOnlineLabel => _t('online', 'آنلاین');
  String get today => _t('Today', 'امروز');
  String get yesterday => _t('Yesterday', 'دیروز');
  String get replyTo => _t('Reply to', 'پاسخ به');
  String get slideToCancel => _t('Slide away to cancel', 'برای لغو بکشید');
  String get deletedMsg => _t('Message deleted', 'پیام حذف شد');
  String get delete => _t('Delete', 'حذف');
  String get copy => _t('Copy', 'کپی');
  String get reply => _t('Reply', 'پاسخ');
  String get cancel => _t('Cancel', 'لغو');
  String get send => _t('Send', 'ارسال');
  String get save => _t('Save', 'ذخیره');
  String get photo => _t('Photo', 'عکس');
  String get emptyChatTitle => _t('No messages yet', 'هنوز پیامی نیست');
  String get emptyChatSub => _t('Say hi 👋', 'سلام بگو 👋');
  String get loadEarlier => _t('Load earlier messages', 'پیام‌های قبلی');
  String get msgFailed => _t('Not sent — tap to retry', 'ارسال نشد — برای تلاش مجدد بزن');
  String get noChatsTitle => _t('No chats here yet', 'فعلاً چتی اینجا نیست');
  String get noChatsSub => _t('Start a conversation from the + button', 'از دکمه + یک گفتگو را شروع کن');
  String get newChat => _t('New chat', 'چت جدید');
  String get newPv => _t('New private chat', 'چت خصوصی جدید');
  String get newGroup => _t('New group', 'گروه جدید');
  String get groupName => _t('Group name', 'نام گروه');
  String get create => _t('Create', 'ساخت');
  String get startPvSub => _t('Enter a username to start chatting', 'نام کاربری را وارد کنید تا گفتگو شروع شود');
  String get userNotFound => _t('User not found', 'کاربر پیدا نشد');
  String get joined => _t('Joined', 'عضویت');

  // magazine
  String get magSearchPh => _t('Search magazines and posts', 'جستجوی مجله‌ها و پست‌ها');
  String get share => 'Share';
  String get view => _t('View', 'مشاهده');
  String get learnMore => _t('Learn more', 'بیشتر بدانید');

  // profile
  String get followers => _t('followers', 'دنبال‌کننده');
  String get following => _t('following', 'دنبال‌شده');
  String get posts => _t('Posts', 'پست‌ها');
  String get tabPosts => _t('Posts', 'پست‌ها');
  String get tabAbout => _t('About', 'درباره');
  String get tabProjects => _t('Projects', 'پروژه‌ها');
  String get editProfile => _t('Edit profile', 'ویرایش پروفایل');
  String get editProfileSub => _t('Name, username, photo & bio', 'نام، نام کاربری، عکس و بایو');
  String get customizeProfile => _t('Customize profile', 'شخصی‌سازی پروفایل');
  String get customizeProfileSub => _t('Theme, cover & frame (Pro)', 'تم، کاور و قاب (Pro)');
  String get blockedUsers => _t('Blocked users', 'کاربران مسدودشده');
  String get blockedUsersSub => _t("Manage who you've blocked", 'مدیریت مسدودشده‌ها');
  String get logout => _t('Log out', 'خروج');
  String get logoutSub => _t('Sign out of your RAVI account', 'خروج از حساب RAVI');
  String get noBio => _t('No bio yet — tap Edit Profile to add one.', 'هنوز بایویی نیست — برای افزودن، ویرایش پروفایل را بزنید.');
  String get name => _t('Name', 'نام');
  String get joinedLabel => _t('Joined', 'عضویت');
  String get shareFirstPost => _t('Share your first post', 'اولین پستت را منتشر کن');
  String get stayTuned => _t('Stay tuned for updates', 'به‌زودی با خبرهای جدید');
  String get nothingHere => _t('Nothing here yet', 'فعلاً چیزی اینجا نیست');

  // settings
  String get settingsTitle => _t('Settings', 'تنظیمات');
  String get grpAppearance => _t('Appearance', 'ظاهر');
  String get grpAccount => _t('Account', 'حساب');
  String get grpNotify => _t('Notifications & Sound', 'اعلان‌ها و صدا');
  String get grpPrivacy => _t('Privacy & Security', 'حریم خصوصی و امنیت');
  String get grpAbout => _t('About Ravi', 'درباره Ravi');
  String get displayMode => _t('Display mode', 'حالت نمایش');
  String get themeLight => _t('Light', 'روشن');
  String get themeDark => _t('Dark', 'تاریک');
  String get themeSystem => _t('System', 'سیستم');
  String get accentTitle => _t('Accent color', 'رنگ تأکیدی');
  String get accentSub => _t('Color of buttons & highlights', 'رنگ دکمه‌ها و بخش‌های برجسته');
  String get chatBg => _t('Chat background', 'پس‌زمینه چت');
  String get chatBgDefault => _t('Default pattern', 'الگوی پیش‌فرض');
  String get language => _t('Language', 'زبان');
  String get textSize => _t('Text size', 'اندازه متن');
  String get textSizeStandard => _t('Standard', 'استاندارد');
  String get myAccount => _t('My account', 'حساب من');
  String get phone => _t('Phone number', 'شماره تلفن');
  String get phoneSub => _t('For login & account recovery', 'برای ورود و بازیابی حساب');
  String get notifications => _t('Notifications', 'اعلان‌ها');
  String get notifSub => _t('Messages & magazine', 'پیام‌ها و مجله');
  String get sounds => _t('Sounds', 'صداها');
  String get soundsSub => _t('Message & call sounds', 'صدای پیام و تماس');
  String get privacy => _t('Privacy & Security', 'حریم خصوصی و امنیت');
  String get privacySub => _t('Manage access & sessions', 'مدیریت دسترسی و نشست‌ها');
  String get sessionsTitle => _t('Active sessions', 'نشست‌های فعال');
  String get sessionsSub => _t('Devices signed in to your account', 'دستگاه‌های واردشده به حسابتان');
  String get passwordLogin => _t('Password & login', 'رمز و ورود');
  String get passwordSub => _t('Account security', 'امنیت حساب');
  String get aboutRavi => _t('About Ravi', 'درباره Ravi');
  String get aboutSub => _t('Beta version 1.0 — unified chats', 'نسخه بتا ۱.۰ — چت یکپارچه');

  // misc
  String get saved => _t('Saved', 'ذخیره شد');
  String get copied => _t('Copied', 'کپی شد');
  String get error => _t('Something went wrong', 'مشکلی پیش آمد');
  String get retry => _t('Retry', 'تلاش مجدد');
  String get offlineHint => _t('Offline — messages will send when connected',
      'آفلاین — پیام‌ها بعد از اتصال ارسال می‌شوند');

  // ---- v1.0.5 ----
  String get viewProfile => _t('View profile', 'مشاهده پروفایل');
  String get profile => _t('Profile', 'پروفایل');
  String get message => _t('Message', 'پیام');
  String get follow => _t('Follow', 'دنبال کردن');
  String get unfollow => _t('Unfollow', 'دنبال نکردن');
  String get followedToast => _t('You followed', 'دنبال کردید:');
  String get unfollowedToast => _t('You unfollowed', 'دنبال کردن لغو شد:');
  String get block => _t('Block', 'مسدود کردن');
  String get blockedToast => _t('User blocked', 'کاربر مسدود شد');
  String get followersOf => _t('Followers', 'فالوئرها');
  String get followingOf => _t('Following', 'فالوینگ');
  String get emptyFollowers => _t('Nobody here yet', 'هنوز کسی اینجا نیست');
  String get members => _t('Members', 'اعضا');
  String get subscribers => _t('Subscribers', 'مشترکین');
  String get owner => _t('Owner', 'مالک');
  String get roomAdmin => _t('Admin', 'ادمین');
  String get viewInfo => _t('Info', 'اطلاعات');
  String get inviteLinkCopied => _t('Invite link copied', 'لینک دعوت کپی شد');
  String get noBioYet => _t('No bio', 'بدون بایو');

  // create chat
  String get createGroup => _t('New group', 'گروه جدید');
  String get createChannel => _t('New channel', 'کانال جدید');
  String get channelName => _t('Channel name', 'نام کانال');
  String get publicToggle => _t('Public — join by link', 'عمومی — با لینک/آیدی');
  String get publicHandle => _t('Public link', 'لینک عمومی');
  String get handleAvailable => _t('Available ✓', 'در دسترس است ✓');
  String get handleTaken => _t('Already taken', 'قبلاً گرفته شده');
  String get handleInvalid => _t('Invalid (a-z, 0-9, _)', 'نامعتبر (a-z، 0-9، _)');
  String get checkingHandle => _t('Checking…', 'در حال بررسی…');
  String get usernameAvailable => _t('Available ✓', 'در دسترس است ✓');
  String get usernameTaken => _t('Already taken', 'قبلاً گرفته شده');
  String get created => _t('Created 🎉', 'ساخته شد 🎉');
  String get createFailed => _t('Could not create', 'ساخته نشد');

  // media picker
  String get photoVideo => _t('Photo / Video', 'عکس / ویدیو');
  String get camera => _t('Camera', 'دوربین');
  String get music => _t('Music', 'موزیک');
  String get sendPhoto => _t('Send', 'ارسال');
  String get addCaption => _t('Add a caption…', 'یک کپشن اضافه کن…');
  String get cropPhoto => _t('Crop', 'برش');
  String get savedToGallery => _t('Saved to gallery', 'در گالری ذخیره شد');
  String get saveFailed => _t('Could not save', 'ذخیره نشد');
  String get videoFile => _t('Video', 'ویدیو');
  String get audioFile => _t('Audio', 'صدا');
  String get unsupportedFile => _t('Format not supported (jpg png gif webp mp4 webm mp3 ogg m4a)',
      'فرمت مجاز نیست (jpg png gif webp mp4 webm mp3 ogg m4a)');

  // voice
  String get holdToRecord => _t('Hold to record', 'نگه دارید تا ضبط شود');
  String get recording => _t('Recording…', 'در حال ضبط…');
  String get releaseToSendVoice => _t('Release to send — slide away to cancel', 'رها کنید تا ارسال شود — بکشید تا لغو شود');
  String get micPermission => _t('Microphone permission is needed', 'دسترسی میکروفون لازم است');
  String get voiceTooShort => _t('Too short', 'خیلی کوتاه بود');

  // customize profile (Pro)
  String get proOnlyTitle => _t('Pro feature', 'قابلیت Pro');
  String get proOnlyBody => _t('Themes, covers and frames are for Pro accounts. Ask the admin to upgrade your account.',
      'تم، کاور و قاب مخصوص حساب‌های Pro است. برای ارتقا به ادمین اطلاع دهید.');
  String get mustBePro => _t('You need Pro for this', 'برای این قابلیت باید Pro باشید');
  String get avatarFrameTitle => _t('Avatar frame', 'قاب عکس پروفایل');
  String get noFrame => _t('None', 'بدون قاب');
  String get themeTitle => _t('Profile theme', 'تم پروفایل');
  String get cardColorTitle => _t('Card color', 'رنگ کارت');
  String get coverTitle => _t('Cover photo', 'عکس کاور');
  String get uploadCover => _t('Upload cover', 'بارگذاری کاور');
  String get removeCover => _t('Remove cover', 'حذف کاور');
  String get applied => _t('Applied ✓', 'اعمال شد ✓');

  // chat background
  String get wallpaperTitle => _t('Chat wallpaper', 'والپیپر چت');
  String get wallpaperSub => _t('Pick a background for all chats', 'پس‌زمینه همه‌ی چت‌ها را انتخاب کنید');
  String get useCustomPhoto => _t('Custom photo', 'عکس دلخواه');
  String get resetWallpaper => _t('Default', 'پیش‌فرض');
  String get previewLabel => _t('Live preview', 'پیش‌نمایش زنده');

  // accent
  String get accentPickTitle => _t('Accent color', 'رنگ تأکیدی');

  // reactions / misc chat
  String get openProfileHint => _t('', '');
  String get dmClosedBanner => _t('This user does not accept new messages', 'پیام‌های این کاربر بسته است');
  String get blockedBanner => _t('You blocked this user', 'این کاربر را مسدود کرده‌اید');
  String get unblockAndChat => _t('Unblock', 'رفع مسدودی');
  String get channelPostOnly => _t('Only admins can post here', 'فقط ادمین‌ها می‌توانند پست بگذارند');

  // ---- v1.0.6 ----
  String get forward => _t('Forward', 'فوروارد');
  String get forwardTo => _t('Forward to', 'فوروارد به');
  String get forwardedToast => _t('Forwarded ✓', 'فوروارد شد ✓');
  String get forwardedMsg => _t('Forwarded', 'فوروارد شده');
  String get download => _t('Download', 'دانلود');
  String get downloading => _t('Downloading…', 'در حال دانلود…');
  String get downloadDone => _t('Downloaded', 'دانلود شد');
  String get downloadFailed => _t('Download failed', 'دانلود نشد');
  String get uploadLabel => _t('Uploading', 'در حال ارسال');
  String get uploadDone => _t('Uploaded', 'ارسال شد');
  String get sendFailedToast => _t('Sending failed', 'ارسال نشد');
  String get joinedRoomToast => _t('Joined ✓', 'عضو شدید ✓');
  String get roomNotFound => _t('Channel or group not found', 'چنین کانال یا گروهی پیدا نشد');
  String get joining => _t('Joining…', 'در حال عضویت…');
  String get join => _t('Join', 'عضویت');
  String get openRoom => _t('Open', 'باز کردن');
  String get openChat => _t('Open chat', 'باز کردن چت');
  String get roomBioLabel => _t('Description', 'درباره');
  String get deleteMsgTitle => _t('Delete message?', 'پیام حذف شود؟');
  String get deleteMsgConfirm => _t('This message will be removed for everyone.', 'این پیام برای همه حذف می‌شود.');
  String get lockRecord => _t('Slide up to lock', 'برای قفل کردن به بالا بکشید');
  String get lockedRecord => _t('Recording locked', 'ضبط قفل شد');
  String get cancelRecord => _t('Cancel', 'لغو');
  String get stopRecord => _t('Stop', 'توقف');
  String peopleTyping(int n) => _t('$n people are typing', '$n نفر در حال نوشتن');
  String get andMoreTyping => _t('and', 'و');
  String get lastSeenRecently => _t('last seen recently', 'آخرین بازدید به‌تازگی');
  String get lastSeenAt => _t('last seen', 'آخرین بازدید');
  String get unblockUser => _t('Unblock user', 'رفع مسدودی کاربر');
  String get unblockedToast => _t('User unblocked', 'مسدودی برداشته شد');
  String get reportUser => _t('Report', 'گزارش');
  String get confirmReport => _t('Report this user?', 'این کاربر گزارش شود؟');
  String get reportDone => _t('Reported', 'گزارش ثبت شد');
  String get more => _t('More', 'بیشتر');
  String get postsLabel => _t('Posts', 'پست‌ها');
  String get noPostsYet => _t('No posts yet', 'هنوز پستی نیست');
  String get bioEmptyHint => _t("This user hasn't added a bio yet.", 'این کاربر بایویی اضافه نکرده است.');
  String get blockedTag => _t('Banned', 'مسدود');
  String get adminTag => _t('Admin', 'ادمین');
  String get starTag => _t('Star', 'ستاره');
  String get gotoChat => _t('Message', 'پیام');

  // ---- v1.0.8 — header subtitle, menus, music, contacts/calls ----
  String membersOnline(int n) => _t('$n online', '$n آنلاین');
  String membersWithOnline(int members, int online) =>
      _t('$members members, $online online', '$members عضو، $online آنلاین');
  String subscribersCount(int n) => _t('$n subscribers', '$n مشترک');
  String get chatMenuInfo => _t('Info', 'اطلاعات');
  String get chatMenuMute => _t('Mute', 'بی‌صدا');
  String get chatMenuUnmute => _t('Unmute', 'صدا دار');
  String get chatMenuLeave => _t('Leave', 'خروج');
  String get chatMenuAI => _t('Ravi AI', 'هوش مصنوعی');
  String get chatMenuAISoon => _t('Ravi AI — coming soon', 'هوش مصنوعی — به‌زودی');
  String get leaveConfirmTitle => _t('Leave?', 'خروج؟');
  String leaveConfirmBody(String name) =>
      _t('Leave "$name"? You can rejoin later with the invite link.',
          'از «$name» خارج می‌شوید؟ بعداً با لینک دعوت می‌توانید برگردید.');
  String get leftRoomToast => _t('You left', 'خارج شدید');
  String get ownerCannotLeave => _t('Transfer ownership first', 'ابتدا مالکیت را منتقل کنید');
  String get mutedToast => _t('Muted', 'بی‌صدا شد');
  String get unmutedToast => _t('Unmuted', 'صدا دار شد');
  String get banMember => _t('Ban', 'اخراج');
  String get unbanMember => _t('Unban', 'رفع اخراج');
  String get promoteAdmin => _t('Promote to admin', 'ارتقا به ادمین');
  String get demoteAdmin => _t('Dismiss admin', 'سلب ادمینی');
  String bannedMemberToast(String name) => _t('$name was banned', '$name اخراج شد');
  String promotedToast(String name) => _t('$name is now admin', '$name ادمین شد');
  String demotedToast(String name) => _t('$name is no longer admin', '$name دیگر ادمین نیست');
  String get bannedListTitle => _t('Banned users', 'اخراج‌شده‌ها');
  String get manageMembers => _t('Manage', 'مدیریت');
  String get nowPlayingTitle => _t('Now playing', 'در حال پخش');
  String get voiceMessageLabel => _t('Voice message', 'پیام صوتی');
  String get releaseToSend => _t('Release to send', 'رها کنید تا ارسال شود');
  String get contactsTitle => _t('Contacts', 'مخاطبین');
  String get contactsSub => _t('People you chat with', 'کسانی که با آنها چت کرده‌اید');
  String get callsTitle => _t('Calls', 'تماس‌ها');
  String get callsEmptyTitle => _t('No calls yet', 'هنوز تماسی نیست');
  String get callsEmptySub => _t('Voice calls are coming to RAVI soon', 'تماس صوتی به‌زودی به RAVI می‌آید');
  String get noContacts => _t('Start a chat to see people here', 'چت را شروع کنید تا مخاطبین‌تان اینجا دیده شوند');
  String get emojiTab => _t('Emoji', 'ایموجی');
  String get gifTab => _t('GIFs', 'گیف‌ها');
  String get reportSent => _t('Report sent ✓', 'گزارش ارسال شد ✓');
  String get aiComingSoon => _t('Ravi AI is coming soon', 'Ravi AI به‌زودی می‌آید');

  // ---- v1.0.9 — big update ----
  // block real-time
  String get blockedYouBanner =>
      _t("You can't send messages to this user", 'شما نمی‌توانید به این کاربر پیام دهید');
  String get youBlockedBanner =>
      _t('You blocked this user — undo to chat', 'این کاربر را مسدود کرده‌اید — برای چت رفع مسدودی کنید');
  String get blockedLiveToast => _t('You were blocked by this user', 'شما توسط این کاربر مسدود شدید');
  String get unblockedLiveToast => _t('You were unblocked', 'مسدودی شما برداشته شد');
  // selection mode
  String get selectMessages => _t('Select messages', 'انتخاب پیام‌ها');
  String selectedCount(int n) => _t('$n selected', '$n پیام انتخاب شد');
  String get deleteSelected => _t('Delete', 'حذف');
  String get forwardSelected => _t('Forward', 'فوروارد');
  String get clearSelection => _t('Clear', 'پاک کردن');
  String get selectHint => _t('Tap messages to select them', 'برای انتخاب، روی پیام‌ها بزنید');
  // forward mode
  String get forwardTitle => _t('Forward to…', 'فوروارد به…');
  String forwardSent(int n) => _t('Forwarded to $n chats ✓', 'به $n چت فوروارد شد ✓');
  String get forwardNothing => _t('Pick at least one chat', 'حداقل یک چت انتخاب کنید');
  // archive
  String get archive => _t('Archive', 'بایگانی');
  String get unarchive => _t('Unarchive', 'خروج از بایگانی');
  String get archivedChats => _t('Archived chats', 'چت‌های بایگانی‌شده');
  String get archivedToast => _t('Chat archived', 'چت بایگانی شد');
  String get unarchivedToast => _t('Chat restored', 'چت بازگردانده شد');
  // edit-in-composer
  String get editingMsg => _t('Editing message', 'در حال ویرایش پیام');
  // slow mode
  String slowModeWait(int n) => _t('Slow mode: wait $n s', 'حالت آهسته: $n ثانیه صبر کنید');
  String get slowMode => _t('Slow mode', 'حالت آهسته');
  String get slowModeSub => _t('Limit how often members can send', 'محدودیت ارسال پیام اعضا');
  String get slowModeOff => _t('Off', 'خاموش');
  String slowModeSec(int n) => _t('$n seconds', '$n ثانیه');
  // group manage / admin rights
  String get adminRights => _t('Admin rights', 'دسترسی‌های ادمین');
  String get permChangeInfo => _t('Change chat info', 'تغییر اطلاعات چت');
  String get permDeleteMessages => _t('Delete messages', 'حذف پیام‌ها');
  String get permBanMembers => _t('Ban members', 'اخراج اعضا');
  String get permRestrict => _t('Restrict members', 'محدودسازی اعضا');
  String get permPromote => _t('Add new admins', 'افزودن ادمین جدید');
  String get memberPermissions => _t('Members can…', 'اعضا می‌توانند…');
  String get permsSendMedia => _t('Send media', 'ارسال رسانه');
  String get permsSendGifs => _t('Send GIFs', 'ارسال گیف');
  String get onlyAdminsPost => _t('Only admins can post', 'فقط ادمین‌ها پیام بدهند');
  String get chatLockedToast => _t('Chat locked — only admins can write', 'چت قفل شد — فقط ادمین‌ها می‌توانند بنویسند');
  String get chatUnlockedToast => _t('Chat unlocked for everyone', 'چت برای همه باز شد');
  String get saveChanges => _t('Save', 'ذخیره');
  String get adminTitleLabel => _t('Admin title', 'عنوان ادمین');
  String get adminTitleHint => _t('e.g. Moderator', 'مثلاً مدیر ارشد');
  String get adminSaved => _t('Admin rights saved ✓', 'دسترسی‌های ادمین ذخیره شد ✓');
  String get promoteTitle => _t('Promote to admin', 'ارتقا به ادمین');
  String get promoteSub => _t('Choose what this admin can do', 'انتخاب کنید این ادمین چه کارهایی بتواند بکند');
  // info screen tabs
  String get tabMembers => _t('Members', 'اعضا');
  String get tabMedia => _t('Media', 'رسانه');
  String get tabLinks => _t('Links', 'لینک‌ها');
  String get tabMusic => _t('Music', 'موزیک');
  String get tabFiles => _t('Files', 'فایل‌ها');
  String get noMediaYet => _t('No media yet', 'هنوز رسانه‌ای نیست');
  String get noLinksYet => _t('No links yet', 'هنوز لینکی نیست');
  String get noMusicYet => _t('No music yet', 'هنوز موزیکی نیست');
  String get infoDesc => _t('Info', 'درباره');
  String get notifToggleLabel => _t('Notifications', 'اعلام‌ها');
  String get lastSeenLongAgoLabel => _t('last seen a long time ago', 'آخرین بازدید مدتی طولانی پیش');
  // privacy screen
  String get privacyLastSeenTitle => _t('Last seen & online', 'آخرین بازدید و آنلاین');
  String get privacyLastSeenSub => _t('Who can see your last seen', 'چه کسی آخرین بازدید شما را ببیند');
  String get privacyDmTitle => _t('Who can message me', 'چه کسی بتواند پیام بدهد');
  String get privacyDmSub => _t('Incoming message permission', 'دسترسی پیام‌های ورودی');
  String get privEveryone => _t('Everyone', 'همه');
  String get privContacts => _t('My contacts', 'مخاطبین من');
  String get privNobody => _t('Nobody', 'هیچ‌کس');
  String get privacySavedToast => _t('Privacy updated ✓', 'حریم خصوصی به‌روز شد ✓');
  // sessions screen
  String get sessionsCurrent => _t('This device', 'این دستگاه');
  String get sessionsOther => _t('Other sessions', 'سایر نشست‌ها');
  String get terminateSession => _t('Terminate', 'خروج اجباری');
  String get terminateAll => _t('Terminate all other sessions', 'خروج از همه‌ی نشست‌های دیگر');
  String get sessionsEmpty => _t('No other active sessions', 'نشست فعال دیگری وجود ندارد');
  String get sessionTerminatedToast => _t('Session terminated', 'نشست خاتمه یافت');
  String get sessionsAllTerminated => _t('All other sessions terminated', 'همه‌ی نشست‌های دیگر خاتمه یافت');
  // text size
  String get textSizeSub => _t('Applies to chat messages', 'روی پیام‌های چت اعمال می‌شود');
  // wallpaper / bubble color
  String get bgPackTitle => _t('Ravi backgrounds', 'پس‌زمینه‌های Ravi');
  String get myWallpapers => _t('Your wallpapers', 'والپیپرهای شما');
  String get addWallpaper => _t('Add from gallery', 'افزودن از گالری');
  String get removeWallpaper => _t('Remove', 'حذف');
  String get wallpaperAdded => _t('Wallpaper added ✓', 'والپیپر اضافه شد ✓');
  String get wallpaperRemoved => _t('Wallpaper removed', 'والپیپر حذف شد');
  String get bubbleColor => _t('Bubble color', 'رنگ حباب‌ها');
  String get bubbleColorSub => _t('Personalize your own bubbles', 'رنگ حباب پیام‌های خودت');
  // followers panel
  String get followBack => _t('Follow back', 'فالو بک');
  String get openProfile => _t('Open profile', 'مشاهده پروفایل');
  // chat list row fixes
  String get typingRow => _t('typing…', 'در حال نوشتن…');
  String get voiceRow => _t('Voice message', 'پیام صوتی');
  String get mediaRow => _t('Photo', 'عکس');
  String get videoRow => _t('Video', 'ویدیو');
  String get musicRow => _t('Music', 'موزیک');
  String get fileRow => _t('File', 'فایل');
  String get gifRow => _t('GIF', 'گیف');
  String get onlyAdminCanDeleteToast =>
      _t('Only admins can delete others\' messages', 'فقط ادمین‌ها می‌توانند پیام دیگران را حذف کنند');
  String get joinGroupBtn => _t('Join', 'عضویت');
  String get linkLabel => _t('Link', 'لینک');
  String get downloadPct => _t('Downloading', 'در حال دانلود');
}
