#!/usr/bin/perl

# Scans through the current working directory, and looks for
# files with suffix ".dash.H.log" which, as per expectation,
# should contain the output from "gcc -H" or "clang -H" or 
# similar compiler.
# 
# Output from -H contains the includes, indented as per the depth of
# the include, and this script
# looks for headers at depth 1, and counts how many headers 
# a given header would then pull in.
# The multiple of both is the factor that can be used as a load_factor
# to decide which headers should go into precompiled headers.
# 
# When done, writes a CSV with four columns: 
# File,	times_included_at_depth_1,	headers_it_includes,	load_factor

use strict;
use warnings;

my $hash = {};
use File::Find;

find(\&wanted, ".");

sub wanted {
	chomp;
	if (/\.dash\.H\.log$/ ) {  
		my $times_included_bumped = 0;
		my $header_depth1;

		open(F,"<$_") or die("failed to open $File::Find::name $!\n");
		while(<F>) {
			next if ( ! /^\.+/ ); 
			chomp();
			my @temp = split(/ /);
			my $header = $temp[1];
			( $header !~ /\.h$/ ) and next;
			if ( $temp[0] eq "." ) {

				if ( defined($header_depth1 ) ) {
					$hash->{$header_depth1}->{headers_it_includes_counted} = 1;
				} #Reset the previous one.

				$header_depth1 = $header;
				if ( !defined($hash->{$header_depth1}) ) {
					$hash->{$header_depth1} = {};
					$hash->{$header_depth1}->{times_included} = 1; 
					$hash->{$header_depth1}->{headers_it_includes} = 1; 
					$hash->{$header_depth1}->{headers_it_includes_counted} = 0; 
				} else {
					$hash->{$header_depth1}->{times_included}++; 
				}
			} else {
				if ( $hash->{$header_depth1}->{headers_it_includes_counted} == 0 )  {
					$hash->{$header_depth1}->{headers_it_includes} ++; 
				}
			}
		}
		close(F);
	}
}

print "---------------------------------\n";
open(F,">results.csv") or die("failed to open results.csv: $!");
print F "File,times_included_at_depth_1,headers_it_includes,load_factor\n";
foreach(keys(%{$hash})) {
	my $times_included = $hash->{$_}->{times_included};
	my $headers_it_includes = $hash->{$_}->{headers_it_includes};
	my $load_factor = $times_included  * $headers_it_includes;
	print (F "$_,$times_included,$headers_it_includes, $load_factor\n");
}
close(F);
