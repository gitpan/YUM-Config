use 5.008006;
use ExtUtils::MakeMaker;
WriteMakefile(
	NAME				=> 'YUM::Config',
	VERSION_FROM		=> 'lib/YUM/Config.pm',
	PREREQ_PM			=> {
							RPM2,
							LWP::UserAgent,
							FreezeThaw,
							Config::IniHash,
							Hash::Merge,
							File::Temp,
							File::Remove,
							XML::LibXML,
							Sort::Versions,
							PerlIO::gzip
						},
	($] >= 5.005 ?
		(ABSTRACT_FROM	=> 'lib/YUM/Config.pm',
		AUTHOR			=> 'Oliver Falk <oliver@linux-kernel.at>') : ()),
	dist				=> {
		COMPRESS => 'gzip --force --best'
	},
);
