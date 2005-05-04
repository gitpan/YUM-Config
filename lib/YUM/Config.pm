package YUM::Config;

# I cannot live without this.
use 5.008006;
use strict;
use warnings;

# Modules usually require the Exporter...
require Exporter;

# Some modules that are used within this package.
use RPM2;
use LWP::UserAgent;
use FreezeThaw qw/thaw safeFreeze/;
use Config::IniHash;
use Hash::Merge qw/merge/;
use File::Temp qw/tempfile/;
use File::Remove qw/remove/;
use Cache::File;
use XML::LibXML;
use Sort::Versions;
use PerlIO::gzip;

# The usual package stuff...
our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(
) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(
);

# Define our version, comes from CVS.
(our $VERSION) = '$Revision: 1.3 $' =~ /([\d.]+)/;

# The new function is used to create an instance of this package.
# You can define various things. Please have a look at the documentation
# eg. perldoc YUM::Config
sub new {
	my $class = shift;
	my $args = shift;
	my $self = {};

	# Some things can be/must be predefined and cannot be changed afterwards
	# Shall we use Cache::File, to cache the downloaded data?
	$self->{use_cache} = $args->{use_cache} || 0;
	# By default we read /etc/yum.conf, but you can define another, if yours
	# resides somewhere else eg. /usr/local/etc/yum.conf, or whatever...
	$self->{yum_conf} = $args->{yum_conf} || '/etc/yum.conf';
	# By default (at least within RH/FC machines), the yum.repos.d is in /etc.
	# You can define another location if you must.
	$self->{yum_repos_d} = $args->{yum_repos_d} || '/etc/yum.repos.d';
	# You can define another agent string (this is passed to LWP::UserAgent), if you
	# don't want to expose, that YUM::Config is used...
	$self->{agent} = $args->{agent} || "YUM::Config/$VERSION";
	# The RH/FC release version is read by asking the rpmdb for /etc/redhat-release
	# If you want to override, please feel free to do so...
	$self->{releasever} = $args->{releasever} || undef;
	# You can override the basearch, if you must, but normally, it is
	# discovered automatically (and correctly?).
	$self->{basearch} = $args->{basearch} || undef;
	# Define you you want to download the primary.xml.gz and parse it.
	$self->{download_primary} = $args->{download_primary} || undef;

	# If caching is enabled, instanciate a cache object within self.
	if($self->{use_cache}) {
		$self->{cache} = Cache::File->new(
			cache_root		=> $args->{cache_root} || '/tmp/YUM_Config',
			default_expires	=> $self->{cache_expires} || '12 hours',
		);
	}

	# Bless ourself into the class.
	bless($self, $class);
	return $self;
}

# The parse function it the main function. It reads the yum.conf
# parses it using ReadINI (from Config::IniHash). Afterwards it
# looks for an include and also parses it with Config::IniHash.
# Afterwards Hash::Merge is used to merge the two hashes.
# The release version is discovered, if not yet defined (at new).
# The basearch is discovered, if not yet defined (at new).
sub parse {
	my $self = shift;

	# Get the currrent release version.
	unless($self->{releasever}) {
		my $rpmdb = RPM2->open_rpm_db();
		foreach($rpmdb->find_by_file("/etc/redhat-release")) {
			$self->{releasever} = $_->version();
		}
		undef $rpmdb;
	}

	# Get the basearch
	unless($self->{basearch}) {
		# TODO/NOTE: This works on Red Hat / Fedora, does it work somewhere else,
		# where yum is used as well?
		my $basearch = `uname -i`;
		chomp($basearch);
		$self->{basearch} = $basearch;
	}

	# Read in the yum.conf
	$self->{__yumconf_local} = ReadINI($self->{yum_conf});

	# Check if the yum.repos.d directory exists and if so, add the files
	# (allready parsed) to the yumconf_local
	if(-d $self->{yum_repos_d}) {
		opendir(DIR, $self->{yum_repos_d});
		foreach(readdir(DIR)) {
			next if /^\./;
			if(-f $self->{yum_repos_d}."/".$_) {
				my $repo = ReadINI($self->{yum_repos_d}."/".$_);
				foreach my $k (keys %{$repo}) {
					$self->{__yumconf_local}->{$k} = $repo->{$k};
				}
			}
		}
		closedir(DIR);
	}

	# Get the include file, if there is one
	# and merge it with the local one
	if($self->{__yumconf_local}->{main}->{include}) {
		Hash::Merge::set_behavior('RIGHT_PRECEDENT');
		$self->{__yumconf_remote} = $self->get_include($self->{__yumconf_local}->{main}->{include});
		$self->{__yumconf} = merge($self->{__yumconf_remote}, $self->{__yumconf_local});
	} else {
		$self->{__yumconf} = $self->{__yumconf_local};
	}

	# Split up the exclude list and provide perl regex, for easier processing
	# Remove disabled repos
	# Download mirrorlists
	foreach my $section (keys %{$self->{__yumconf}}) {
		$self->{__yumconf}->{$section}->{enabled} = 1 unless defined $self->{__yumconf}->{$section}->{enabled};
		if($self->{__yumconf}->{$section}->{enabled}) {
			if($self->{__yumconf}->{$section}->{exclude}) {
				foreach(split(',', $self->{__yumconf}->{$section}->{exclude})) {
					s/\s+//g;
					s/\*/.*/g;
					s/\?/./g;
					$self->{__yumconf}->{$section}->{exclude_hash}->{$_} = 1;
				}
			}

			if($self->{__yumconf}->{$section}->{name}) {
				$self->{__yumconf}->{$section}->{name} = $self->substi($self->{__yumconf}->{$section}->{name});
			}
			
			# If there is a baseurl AND a mirrorlist, we ignore the mirrorlist!
			if($self->{__yumconf}->{$section}->{mirrorlist} && ! $self->{__yumconf}->{$section}->{baseurl}) {
				my @baseurls;
				# Download the mirrorlist
				my $bus = $self->download_url($self->{__yumconf}->{$section}->{mirrorlist});

				# Make the substitutions (basearch, releasever)
				$bus = $self->substi($bus);

				# This is some code that really isn't fine, but as long as I have no time to do
				# it better, it will stay. :-)
				my ($fh, $filename) = tempfile();
				print $fh $bus;
				close($fh);
				open($fh, $filename);
				while(<$fh>) {
					chomp;
					push @baseurls, $_;
				}
				close($fh);
				remove $fh;
				# Provide a baseurl
				$self->{__yumconf}->{$section}->{baseurl} = $baseurls[0];
				# Safe an array of baseurls extra (could be used to make the failover stuff)
				$self->{__yumconf}->{$section}->{baseurls} = @baseurls if @baseurls > 1;
				# Delete the mirrorlist from the hash, as we don't need it any more.
				delete $self->{__yumconf}->{$section}->{mirrorlist};
			} else {
				# Die, if we have no baseurl for some repo. We really should not continue
				# if a repo has no baseurl. Also yum itself dies, if this happens, so we
				# think it's OK/a good idea/solution, name it...
				unless($self->{__yumconf}->{$section}->{baseurl}) {
					die "No baseurl/mirrorlist specified in $section" unless $section =~ /main/;
				} else {
					# Make the substitutions...
					$self->{__yumconf}->{$section}->{baseurl} = $self->substi($self->{__yumconf}->{$section}->{baseurl});
					# Download/parse primary.xml.gz if defined to do so (at new)
					$self->{__yumconf}->{$section}->{primary} = $self->read_primary($self->{__yumconf}->{$section}->{baseurl}.'/repodata/primary.xml.gz') if $self->{download_primary};
				}
			}
		} else {
			# Delete sections that are not enabled (enabled=0)
			delete $self->{__yumconf}->{$section} unless $section =~ /main/;
		}
	}
	$self->{parsed} = 1;
	return $self->{__yumconf};
}

# Returns the parsed local yum.conf
# Parses the yum.conf, if not allready done...
sub yumconf_local {
	my $self = shift;
	$self->parse() unless $self->{parsed};
	return $self->{__yumconf_local};
}

# Returns the parsed remote config
# Parses the yum.conf, if not allready done...
# Return undef, if no remote config is available
sub yumconf_remote {
	my $self = shift;
	$self->parse() unless $self->{parsed};
	return $self->{__yumconf_remote} if $self->{__yumconf_remote};
	return undef
}

# This function is used to download/parse the primary.xml.gz
sub read_primary($) {
	my $self = shift;
	my $url = shift;

	# Let download_url do the stuff with caching (if enabled) and downloading
	my $data = $self->download_url($url);

	# Save it to a tempfile, so we can re-read it.
	my ($fh, $filename) = tempfile();
	print $fh $data;
	close($fh);

	# Re-read the file with gzip.
	open $fh, "<:gzip", $filename or die $!;
	my $prim;
	while(<$fh>) { $prim .= $_; }
	close($fh);

	# Remove the tempfile, as we don't need it any more and we
	# clean up temps usually (arg. we REALLY should!)
	remove $filename;

	# Init the parser;
	my $parser = XML::LibXML->new();
	# read the DOM
	my $dom = $parser->parse_string($prim);
	# get the ROOT element of the DOM
	my $elem = $dom->getDocumentElement();
	my $packages;

	# Might not be the best code you've ever seen, but it works. :-)
	# Run through the xml and get ver, rel, epoch, name out of it.
	# Don't try to rewrite this with XML::Simple, as the file can be huge
	# and XML::Simple will take really much CPU/memory/time to parse...
	foreach my $child($elem->getChildrenByTagName("package")) {
		my $name    = @{$child->getChildrenByTagName("name")}[0]->textContent();
		my $version = @{$child->getChildrenByTagName("version")}[0]->getAttribute("ver");
		my $release = @{$child->getChildrenByTagName("version")}[0]->getAttribute("rel");
		my $epoch   = @{$child->getChildrenByTagName("version")}[0]->getAttribute("epoch");
		# This is black magic. :-)
		# primary.xml.gz also lists older packages, if you don't have a very clean yum-repo
		# This functions checks the epoch first and afterward the version/release...
		# Might be no bad idea to also save the old packages to the hash, but I didn't need
		# this yet...
		if($packages->{$name}) {
			if($epoch > $packages->{$name}->{epoch}) {
				$packages->{$name} = {
					version => $version,
					release => $release,
					epoch   => $epoch,
				};
			} else {
				my $verel1 = $version . "-" . $release;
				my $verel2 = $packages->{$name}->{version} . "-" . $packages->{$name}->{release};
				if(versioncmp($verel1, $verel2) == 1) {
					if($epoch >= $packages->{$name}->{epoch}) {
						$packages->{$name} = {
							version => $version,
							release => $release,
							epoch   => $epoch,
						};
					}
				}
			}
		} else {
			$packages->{$name} = {
				version => $version,
				release => $release,
				epoch   => $epoch,
			};
		}
	}
	return $packages;
}

# Some substitions. 
sub substi ($) {
	my $self = shift;
	my $string = shift;

	# If you have any more yum variables that should be
	# substituted, please write the code and let me know. :-)
	
	# Use the discovered or defined releasever
	$string =~ s/\$releasever/$self->{releasever}/g;
	# Use the discoverd or defined basearch
	$string =~ s/\$ARCH/$self->{basearch}/g;
	$string =~ s/\$basearch/$self->{basearch}/g;
	return $string;
}

# Function, used to download/parse a local or remote yum config,
# specified with include= in yum.conf
sub get_include($) {
	my $self = shift;
	my $inc = shift;

	my $data;

	# If it begins with http:, we need to download it
	# save it to some tempfile and read it with ReadINI
	# Be brave and remove the tempfile and afterwards return
	# the hash the was parse by ReadINI
	if($inc =~ /^http:/)  {
		$data = $self->download_url($inc);
		my ($fh, $filename) = tempfile();
		print $fh $data;
		close($fh);
		my $inc_hash = ReadINI($filename);
		remove $filename;
		return $inc_hash;
	} else {
		# Same here with ftp:
		# WARNING: I never tried if this works!
		if($inc =~ /^ftp:/) {
			$data = $self->download_url($inc);
			my($fh, $filename) = tempfile();
			print $fh $data;
			close($fh);
			my $inc_hash = ReadINI($filename);
			remove $filename;
			return $inc_hash;
		} else {
			# If it begins with slash, it can be directly read with ReadINI
			if($inc =~ /^\//) {
				return ReadINI($inc);
			} else {
				# Try if it is a file, if not we tried a lot of things (http, ftp, local file) and
				# it didn't work; Then we will........
				if(-f $inc) {
						return ReadINI($inc);
				} else {
					# ........ die, as I have no idea, what could be done... Or what scheme this is...#
					die "Unsupported URL scheme found, while trying to include \"$inc\"";
				}
			}
		}
	}
}

# This is a helper function, it will download an url
# and cache it, if caching is enabled.
# Caching is based on the header last-modified. If no last-modified
# is available (eg. some script), the 'date' is used and it will
# download the file every time
# Default cache expires is defined at new, if nothing else is provided
# by the programmer, it's 12 hours. Then the cache will expire...
# It will always download the header if caching is enabled to see, if
# the remote file has changed. If so, renew the cache.
sub download_url ($) {
	my $self = shift;
	my $url = shift;

	# If you do some shit, die.
	die "I cannot download, if you don't provide an URL..." unless $url;

	# Instanciate a new LWP::UserAgent, and provide the defined
	# agent string.
	my $ua = LWP::UserAgent->new(agent => $self->{agent});

	# Check if we want to use a local cache
	if($self->{use_cache}) {

		# Download only the header
		my $head = $ua->head($url);
		my $date = $head->header('last_modified') || $head->header('date');

		# Download was successfull
		if($head->is_success()) {
			my $cache_date = "";
			my $data;
			if(my $cache_entry = $self->{cache}->get($url)) {
				$data = ${\thaw($cache_entry)};
				$cache_date = $data->{url_info}->header('last-modified');
				$cache_date = "" unless $cache_date;
			}
			if($cache_date eq $date) {
				return $data->{userdata};
			}
		} else {
			die "Error while trying to download header from $url: ".$head->status_line();
		}
	}

	# Now there are two possibilities. The cache was too old, or we don't have
	# caching enabled. However, we need to download the file.
	my $res = $ua->get($url);
	if($res->is_success()) {
		if($self->{use_cache}) {
			my $data = {
				userdata	=> $res->content(),
				url_info	=> $res,
			};
			$self->{cache}->set($url, safeFreeze($data));
		}
		return $res->content();
	} else {
		die "Error while trying to download file from $url: ".$res->status_line();
	}
}

# Preloaded methods go here.

1;
__END__

=head1 NAME

YUM::Config - Perl extension for parsing yum.conf

=head1 SYNOPSIS

  use YUM::Config;

  my $yp = new YUM::Config;
  my $yum_conf = $yp->parse();

  foreach(keys %{$yum_conf}) {
	print "Section: $_ is called " . $yum_conf->{$_}->{name} . "\n";
  }

  $yum_conf will be a a hash, all INI sections are the primary hash keys.
  include= will be automatically downloaded merged with the local yum.conf
  mirrorlists will also be downloaded and saved as an array in $yum_conf->{somerepo}->{baseurls}
  the first url in mirrorlists will be safed as $yum_conf->{somerepo}->{baseurl}.
  exclude statements will be splited and safed to $yum_conf->{somerepo}->{exclude_hash}. Note that we
  safe a perl regex string as keys here.

  To say it with one sentence. YUM::Config automatically parses a yum.conf does the downloading and provides you
  with a ready to use perl hash. :-)

  You can define a few things @ new:
	
	- use_cache: 0/1 (1 will enable, default: 0; Uses Cache::File)
	
	- yum_conf: path to your yum.conf (default: /etc/yum.conf)
	
	- yum_repos_d: path to your yum.repos.d (default: /etc/yum.repos.d)
	
	- agent: You LWP::UserAgent agent string (default: YUM::Config/$VERSION)
	
	- releasever: Define your RH/FC release version (rpm -qf --queryformat %{VERSION} /etc/redhat-release; Default: automatically queried)
	
	- basearch: Define your basearch (uname -i; Default: automatically discovered)
	
	- download_primary: Define if we should download/parse the primary.xml.gz
  
  These arguments can be specified this way (don't forget the '{'!)
  my $yp = new YUM::Config({
	  use_cache        => 1,
	  yum_conf         => '/etc/yum.conf',
	  yum_repos_d      => '/etc/yum.repos.d',
	  agent            => 'MyProgram/$VERSION',
	  relasever        => 4,
	  basearch         => 'i386',
	  download_primary => 1
  });
	

=head1 DESCRIPTION

This module provides you with a few functions,


parse() will return a hash containing the allready parsed local/remote yum.conf.

yumconf_local() will return a hash containing the allready parsed local yum.conf
(Will run parse(), if you didn't yet)

yumconf_remote() will return a hash containing the allready parsed remote yum.conf
(Will run parse(), if you didn't yet)


=head2 EXPORT

Nothing.

=head1 BUGS

None, that I'm aware of.

=head1 TODO

Let me know, I like it as it is - currently.

=head1 SEE ALSO

Config::IniHash
Hash::Merge
RPM2
LWP::UserAgent
FreezeThaw
File::Temp
File::Remove
Cache::File
XML::LibXML
Sort::Versions
PerlIO::gzip

=head1 AUTHOR

Oliver Falk, E<lt>oliver@linux-kernel.atE<gt>
linux-kernel.at

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2005 by Oliver Falk

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.6 or,
at your option, any later version of Perl 5 you may have available.

=cut
