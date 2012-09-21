use lib ('.', "../../Tools/perl_lib","perl_lib");
use Cwd;
use Cwd 'abs_path';
use File::Path;
use Getopt::Long;
use Tools qw(InstallNameTool);

my $root = getcwd();
my $monoroot = abs_path($root."/../Mono");
my $skipbuild=0;
my $debug = 0;
my $minimal = 0;
my $iphone_simulator = 0;
my $skipclasslibs = 1;
my $minmacversion = "10.5";
my $sdkversion = "10.5";

GetOptions(
   "skipbuild=i"=>\$skipbuild,
   "debug=i"=>\$debug,
   "minimal=i"=>\$minimal,
   "iphone_simulator=i"=>\$iphone_simulator,
   "skipclasslibs=i"=>\$skipclasslibs
) or die ("illegal cmdline options");

my $arch;
my $uname = `uname -p`;

my $teamcity=0;
if ($ENV{UNITY_THISISABUILDMACHINE})
{
	print "rmtree-ing $root/builds because we're on a buildserver, and want to make sure we don't include old artifacts\n";
	rmtree("$root/builds");
	$teamcity=1;
} else {
	print "not rmtree-ing $root/builds, as we're not on a buildmachine";
	if (($debug==0) && ($skipbuild==0))
	{
		print "\n\nARE YOU SURE YOU DONT WANT TO MAKE A DEBUG BUILD?!?!?!!!!!\n\n\n";
	}
}

if ($iphone_simulator)
{
	$ENV{CFLAGS} = "-DTARGET_IPHONE_SIMULATOR -g -O0";
	$minmacversion = "10.5";
	$sdkversion = "10.5";
}

my $osx_gcc_arguments = " -isysroot /Developer/SDKs/MacOSX$sdkversion.sdk -mmacosx-version-min=$minmacversion ";

for $arch ('i386','x86_64') {
	#libtarget depends on the arch, as we can just link to a ppc dylib and to an i386 dylib and all is fine.
	#bin does not depend on the arch, because we need a mono executable that is a universal binary. Unfortunattely
	#we cannot create a mono universal binary, so we have to lipo that up in a teamcity buildstep

	my $bintarget = "$root/builds/monodistribution/bin-$arch";
	my $libtarget = "$root/builds/embedruntimes/osx-$arch";

	if ($minimal)
	{
		$libtarget = "$root/builds/embedruntimes/osx-minimal";
	}
	print("libtarget: $libtarget\n");

	system("rm $bintarget/mono");
	system("rm $libtarget/libmono.dylib");
	system("rm -rf $libtarget/libmono.dylib.dSYM");

	print "Building for architecture: $arch\n";
	if (not $skipbuild)
	{
		#rmtree($bintarget);
		#rmtree($libtarget);

		#we need to manually set the compiler to gcc4, because the 10.4 sdk only shipped with the gcc4 headers
		#their setup is a bit broken as they dont autodetect this, but basically the gist is if you want to copmile
		#against the 10.4 sdk, you better use gcc4, otherwise things go boink.
		unless ($ENV{CC})
		{
			$ENV{CC} = "gcc-4.0";
		}
		unless ($ENV{CXX})
		{
			$ENV{CXX} = "gcc-4.0";
		}

		if ($debug)
		{
			$ENV{CFLAGS} = "-g -O0 -DMONO_DISABLE_SHM=1 -arch $arch";
			$ENV{LDFLAGS} = "-arch $arch";
		} else
		{
			$ENV{CFLAGS} = "-Os -DMONO_DISABLE_SHM=1 -arch $arch";  #optimize for size
			$ENV{LDFLAGS} = "-arch $arch";
		}

		$ENV{CFLAGS} = $ENV{CFLAGS}.$osx_gcc_arguments ;

		print "cflags = $ENV{CFLAGS}\n";

		print "monoroot is $monoroot\n";	
		chdir("$monoroot") eq 1 or die ("failed to chdir 1");
		#this will fail on a fresh working copy, so don't die on it.
		# system("make distclean");
		#were going to tell autogen to use a specific cache file, that we purposely remove before starting.
		#that way, autogen is forced to do all its config stuff again, which should make this buildscript
		#more robust if other targetplatforms have been built from this same workincopy
		system("rm osx.cache");

		system("autoreconf -i") eq 0 or die ("Failed autoreconfing mono");
		my @autogenparams = ();
		unshift(@autogenparams, "--cache-file=osx.cache");
		if ($skipclasslibs)
		{
			unshift(@autogenparams, "--disable-mcs-build");
		}
		unshift(@autogenparams, "--with-sgen=no");
		unshift(@autogenparams, "--with-glib=embedded");
		unshift(@autogenparams, "--disable-nls");  #this removes the dependency on gettext package
		unshift(@autogenparams, "--with-macversion=$minmacversion");

		# From Massi: I was getting failures in install_name_tool about space
		# for the commands being too small, and adding here things like
		# $ENV{LDFLAGS} = '-headerpad_max_install_names' and
		# $ENV{LDFLAGS} = '-headerpad=0x40000' did not help at all (and also
		# adding them to our final gcc invocation to make the bundle).
		# Lucas noticed that I was lacking a Mono prefix, and having a long
		# one would give us space, so here is this silly looong prefix.
		# unshift(@autogenparams, "--prefix=/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890/1234567890");

		if ($minimal)
		{
			unshift(@autogenparams,"--enable-minimal=aot,logging,com,profiler,debug");
		}

		print("\n\n\n\nCalling configure with these parameters: ");
		system("echo", @autogenparams);
		print("\n\n\n\n\n");
		system("calling ./configure",@autogenparams);
		system("./configure", @autogenparams) eq 0 or die ("failing configuring mono");

		system("make clean") eq 0 or die ("failed make cleaning");
		system("make") eq 0 or die ("failing runnig make for mono");
	}

	chdir($root);

	mkpath($bintarget);
	mkpath($libtarget);

	my $cmdline = "gcc -arch $arch -bundle -reexport_library $monoroot/mono/mini/.libs/libmono-2.0.a $osx_gcc_arguments -all_load -framework CoreFoundation -liconv -o $libtarget/MonoBundleBinary";


	if (!$iphone_simulator)
	{
		print "About to call this cmdline to make a bundle:\n$cmdline\n";
		system($cmdline) eq 0 or die("failed to link libmono.a into mono bundle");

		print "Symlinking libmono.dylib\n";
		system("ln","-f", "$monoroot/mono/mini/.libs/libmono-2.0.dylib","$libtarget/libmono.0.dylib") eq 0 or die ("failed symlinking libmono-2.0.dylib");

		print "Symlinking libmono.a\n";
		system("ln", "-f", "$monoroot/mono/mini/.libs/libmono-2.0.a","$libtarget/libmono.a") eq 0 or die ("failed symlinking libmono-2.0.a");

		if (($arch eq 'i386') and (not $ENV{"UNITY_THISISABUILDMACHINE"}))
		{
			system("ln","-fs", "$monoroot/mono/mini/.libs/libmono-2.0.dylib.dSYM","$libtarget/libmono.0.dylib.dSYM") eq 0 or die ("failed symlinking libmono-2.0.dylib.dSYM");
		}
	 
	#if ($ENV{"UNITY_THISISABUILDMACHINE"})
	#{
	#	system("strip $libtarget/libmono.0.dylib") eq 0 or die("failed to strip libmono");
	#	system("strip $libtarget/MonoBundleBinary") eq 0 or die ("failed to strip MonoBundleBinary");
	#}

	InstallNameTool("$libtarget/libmono.0.dylib", "\@executable_path/../Frameworks/MonoEmbedRuntime/osx/libmono.0.dylib");

	system("ln","-f","$monoroot/mono/mini/mono","$bintarget/mono") eq 0 or die("failed symlinking mono executable");
	system("ln","-f","$monoroot/mono/metadata/pedump","$bintarget/pedump") eq 0 or die("failed symlinking pedump executable");
}

# Create universal binaries
mkpath ("$root/builds/embedruntimes/osx");
mkpath ("$root/builds/monodistribution/bin");
for $file ('MonoBundleBinary','libmono.0.dylib','libmono.a') {
	system ('lipo', "$root/builds/embedruntimes/osx-i386/$file", "$root/builds/embedruntimes/osx-x86_64/$file", '-create', '-output', "$root/builds/embedruntimes/osx/$file");
}
for $file ('mono','pedump') {
	system ('lipo', "$root/builds/monodistribution/bin-i386/$file", "$root/builds/monodistribution/bin-x86_64/$file", '-create', '-output', "$root/builds/monodistribution/bin/$file");
}
}
