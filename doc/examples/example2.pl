#!/usr/bin/perl
#
################################################################################
##
## Projectname - short Project description
##
## Copyright (c) by  Oliver Falk, 2005
##                   oliver@linux-kernel.at
##
## Changes are welcome, but please inform me about those!
##
################################################################################

use strict;
use warnings;

use YUM::Config;

my $yp = new YUM::Config({ use_cache => 1});
#my $yum_config = $yp->parse();

use Data::Dumper;
#print Dumper($yum_config);
#print Dumper($yp);
print Dumper($yp->yumconf_remote());
