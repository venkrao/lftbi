#!/usr/bin/perl

use strict;
use warnings;
use Digest::MD5::File;
use File::Find::Rule;
use Data::Dumper;
use File::Basename qw(basename dirname);

my $i;
my ($objs, $dlls, $libs, $fsindex)  = {};
my @compiler_flags_ignore_list;
my ($gen_source, $depfile, $archive_member_md5);
my $build_target_lib_inputs = "";

my $ignore_these_compiler_flags = "ignore_these_compiler_flags.txt";
my $variable_definition = "variables.txt";
my $proj_root = "";
if ( ! -f $variable_definition ) {
   print ("No $variable_definition file found in the current dir. We need it. Please answer some questions so that a file could be written\n");
   print ("What is the project's top directory path?\n");
   do {
     $proj_root = <STDIN>;
   } while ( $proj_root eq "" );

   open(VD, ">$variable_definition") || die($!);
   print(VD "PATH_ROOT=$proj_root");
   close(VD);
}

my $variables = {};
my ($var, $val);


if ( -f $variable_definition ) {
	open(F, $variable_definition);
	while(<F>) {
		chomp();
		my @temp = split("=");
		$variables->{$temp[0]} = $temp[1];
	}
	close(F);
}

print Dumper($variables);

if ( -f $ignore_these_compiler_flags ) {
  open(F, $ignore_these_compiler_flags);
  while(<F>) {
    /^#/ and next;
    foreach $i (split(/\s+/, $_)) {
      push(@compiler_flags_ignore_list, $i);
    }
  }
}

print Dumper(@compiler_flags_ignore_list);
my $data_struct = {};

my $log = "build.log";
my $build_root = dirname(Cwd::getcwd);

( -f $log ) or die ("Please place the build logs in a file named '$log', 
and run this script from the build workspace top-directory.\n");

my $md5 = Digest::MD5->new;
$md5->addpath($log);

my $log_md5digest = $md5->hexdigest;
( -f $log_md5digest ) and print("#TODO: to not to traverse through the log for this log file, \
that the output of this proram will be stored in a file named '$log_md5digest' \n");

print("$log == $log_md5digest\n");

print("Indexing files of type .o, .so, .a from build root $build_root \n");
print("----------------------------\n");

my @build_arte = File::Find::Rule->file()->name( '*.o', '*.so', '*.a' )->in(("$build_root/do_store"));
my $file_type;

$fsindex->{"basename_to_fullpath"} = {};
$fsindex->{"dll"} = {};
$fsindex->{"dll"}->{"md5sum"} = {};

$fsindex->{"archive"} = {};
$fsindex->{"archive"}->{"md5sum"} = {};

$fsindex->{"object"} = {};
$fsindex->{"object"}->{"md5sum"} = {};

foreach ( @build_arte ) {
  /\.so$/ and $file_type="dll";
  /\.a$/ and $file_type="archive";
  /\.o$/ and $file_type="object";

  $fsindex->{"basename_to_fullpath"}->{basename($_)} = "$_";
  $md5->addpath($_);
  $fsindex->{$file_type}->{"md5sum"}->{basename($_)} = $md5->hexdigest
}

print("Parsing the log file .. $log \n");
open(L, "<$log");

my ($obj, $obj_md5, $source_path);
while(<L>) {
	next if ( ! /do_store\/wmx/ );
	my @logline_as_array = split(/\s+/, $_);
	my $word;
	my ( @compiler_flags, @archive_members, $archive, $archive_md5 );
	if ( /-c / and /\.o/ ) {
		my $compiler = shift(@logline_as_array);
		foreach $word (@logline_as_array) {
			chomp($word);
			if ( $word =~ /^-/ ) {
				# Ok. starts with -, and I call it compiler option.
				# Read through each of ignore pattern, and only if the $word is not in
				# ignore pattern, that we use it as a compiler_flag.
				if (scalar(@compiler_flags_ignore_list) != 0 ) {
                                   foreach my $ignore_this ( @compiler_flags_ignore_list ) {
					if ( $word =~ m/$ignore_this/ ) {
						last;
					}
					if ( $compiler_flags_ignore_list[@compiler_flags_ignore_list - 1 ] eq "$ignore_this" ) {
					 	# Ok. we hit the last element, but it still isnt ignored == it is needed.
						grep (/$word/, @compiler_flags ) or push(@compiler_flags, $word);
					}
				  }
                                } else {
                                   # IF ignore list array is empty, then we just push all compiler arguments as compiler_flags
                                   push(@compiler_flags, $word);
                                }
			}
			if ( $word =~ /\.o$/ ) {
				$obj = $word;
				$obj_md5 = $fsindex->{"object"}->{"md5sum"}->{basename($word)};
			}

			if ( $word =~ /\.(c|cpp|C|cc)$/ ) {
				$source_path = $word;
			}
		}
                if ( ! defined $obj_md5 ) {
                   print("Warning: This is unusual. $source_path or $obj has no md5 in the fsindex. Perhaps a generated file!?\n");
                   next;
                }
		if ( ! defined($data_struct->{"$obj_md5"} )) {
			$data_struct->{"$obj_md5"} = {};
			$data_struct->{"$obj_md5"}->{"source_path"} = $source_path;
			$data_struct->{"$obj_md5"}->{"compiler_path"} = $compiler;
			$data_struct->{"$obj_md5"}->{"compiler_flags"} = "@compiler_flags";
			$data_struct->{"$obj_md5"}->{"object_path"} = $obj;
		}
		next;
	}
	
	if ( /ar / and /\.a/ and /\.o/ ) {
                my ( @common_archive_compiler_flags, @consolidated_compiler_flags); 
                # This holds the compiler flags applicable to 
                # all the archive members.

		# Ok. contains both "ar " with space!, ".a" and ".o"	
		foreach $word (@logline_as_array) {
			if ( $word =~ /\.a$/ and ! defined $archive_md5 ) {
				# The first occurance of .a is the archive name going by 
				# gnu ar usage syntax.
				$archive = basename($word);
				$archive_md5 = $fsindex->{"archive"}->{"md5sum"}->{basename($word)};

				$data_struct->{"$archive_md5"} = {};
				$data_struct->{"$archive_md5"}->{"archive"} = $archive;
				$data_struct->{"$archive_md5"}->{"archive_path"} = $word;
				next; # We dont need to run thru any further..
			}
			if ( $word =~ /\.(a|o|so)$/ ) {
				# This must be an archive member.
				if ( ! defined $data_struct->{"$archive_md5"}->{"archive_members"} ) {
					$data_struct->{"$archive_md5"}->{"archive_members"} = ();
				}
				push( @{$data_struct->{"$archive_md5"}->{"archive_members"}}, $word );

			}
		}

		# The following is somewhat an inefficient implementation. What it does is:
		# To extract the 'per archive' common compiler flags, i.e, compiler flags that are applicable
		# to all the members of a static archive,
		# it first goes throuh compiler flags of all the archive members, and makes a consolidated array
		# with unique compiler flags
		# Then, foreach unique compiler flags consolidated, checks if each of them are present in all
		# the archive members. If present, then, that goes into the common list. The rest of them go to
                # the object's compiler flags list.

		foreach my $archive_member ( @{$data_struct->{"$archive_md5"}->{"archive_members"}} ) {
                        $obj_md5 = $fsindex->{"object"}->{"md5sum"}->{basename($archive_member)};
			foreach my $archive_member_compiler_flag ( split(/\s+/, $data_struct->{"$obj_md5"}->{"compiler_flags"} ) ) {
				if ( ! grep /$archive_member_compiler_flag/, @consolidated_compiler_flags ) {
					push(@consolidated_compiler_flags, $archive_member_compiler_flag );
				}
			}
		}


		my (@archive_common_compiler_flags, $is_common);

		foreach my $compiler_flag ( @consolidated_compiler_flags ) {
		  $is_common = 1;
		  foreach my $archive_member ( @{$data_struct->{"$archive_md5"}->{"archive_members"}} ) {
                        $obj_md5 = $fsindex->{"object"}->{"md5sum"}->{basename($archive_member)};
		        if ( ! grep /$compiler_flag/, split(/\s+/, $data_struct->{"$obj_md5"}->{"compiler_flags"} ) ) {
			    $is_common = 0;
                            last; 
			}
		  }
                  if ( $is_common == 1 ) {
                     push(@archive_common_compiler_flags, $compiler_flag );
		  }
		}

		$data_struct->{"$archive_md5"}->{"compiler_flags"} = "@archive_common_compiler_flags";

		foreach my $archive_member ( @{$data_struct->{"$archive_md5"}->{"archive_members"}} ) {
                        $obj_md5 = $fsindex->{"object"}->{"md5sum"}->{basename($archive_member)};
			my @obj_only_compiler_flags;
			foreach my $archive_member_compiler_flag (split( /\s+/, $data_struct->{"$obj_md5"}->{"compiler_flags"} ) ) {
				if ( ! grep /$archive_member_compiler_flag/, @archive_common_compiler_flags ) {
					push(@obj_only_compiler_flags, $archive_member_compiler_flag );	
				}
			}
			$data_struct->{"$obj_md5"}->{"compiler_flags"} = "@obj_only_compiler_flags";
		}

		$archive_md5 = undef;
		@archive_common_compiler_flags=();
		next;
	}

	if ( /-shared/ and /\.so/ ) {
		# Dynamic library.
		my $linker = shift;
		my ($dll_name, $dll_md5);
		my @dll_members;
		my $ld_flags = "";
		for ( my $i = 0; $i < scalar(@logline_as_array); $i++ ) {
			if ( $logline_as_array[$i] eq "-o" ) {
				# The next word is the dll name.
				$dll_name = $logline_as_array[$i+1];	
				$i = $i+1;
				next;
			}
			if ( $logline_as_array[$i] =~ /\.o$/ ) {
				push(@dll_members, $logline_as_array[$i]);
				next;
			}
			if ( $logline_as_array[$i] =~ /^-/ ) {
				$ld_flags = $ld_flags . " $logline_as_array[$i]";	
			}

		}

		if ( defined $dll_name ) {
		 	$dll_md5 = $fsindex->{"dll"}->{"md5sum"}->{basename($dll_name)};
			
			$data_struct->{"$dll_md5"} = {};
			$data_struct->{"$dll_md5"}->{"ld_flags"} = $ld_flags;
			$data_struct->{"$dll_md5"}->{"linker"} = $linker;
			$data_struct->{"$dll_md5"}->{"dll_members"} = "@dll_members";
			$data_struct->{"$dll_md5"}->{"dll_path"} = $dll_name;
		}
	}
}

print("done.\n----------------------------\n");
close(L);

print ("\nGive me the path to a static lib/object/dll/binary exe file, and I think I can give you details of them\n");
print ("\n---------------------------------------------------------------\n");
while(1) {
	my $input;
	$input = <STDIN>;
	chomp($input);
	if ( $input ne "" ) {
  		( $input =~ /\.so$/ ) and $file_type="dll";
		( $input =~ /\.a$/ ) and $file_type="archive";
		( $input =~ /\.o$/ ) and $file_type="object";

		if ( exists($fsindex->{$file_type}->{"md5sum"}->{basename($input)}) ) {
			my $input_file_md5;
			$input_file_md5  = $fsindex->{$file_type}->{"md5sum"}->{basename($input)};
			print ("Found details of $input... Its Tupfile.lua is as below. \n");
			print ("\n---------------------------------------------------------------\n");
			if ( $file_type eq "archive" ) {
				my $tupfile = <<EOF;
-- Tupfile.lua $input

build_target = {}
build_target["name"] = "$input"
build_target["type"] = "static_lib"						 -- string
build_target["location"] = IMAGE_LIB_DIR .. "/" .. build_target["name"]	  	-- string
build_target["group"] = IMAGE_LIB_DIR .. "/<" .. build_target["name"] .. ">"	-- string


build_target_metadata = {}

build_target_inputs = {} 			-- table 
build_target_command = ""			-- string
build_target_outputs = {} 			-- table

build_target_source_inputs = {}		-- The source files compiled to generate this library.
build_target_dll_inputs = {}		-- The DLLs linked to this library.
build_target_lib_inputs = {}		-- the static libs linked to this library

build_target_source_inputs["compiler_flags"] = "$data_struct->{"$input_file_md5"}->{"compiler_flags"}"
EOF
				print $tupfile . "\n";
				if ( scalar( @{ $data_struct->{$input_file_md5}->{"archive_members"} } ) != 0 ) {
					my $print_rmi_dependency = 0;
					foreach my $archive_member (@{ $data_struct->{$input_file_md5}->{"archive_members"} } ) {
						if ( $archive_member =~ /\.o$/ ) {
							( my $depfile = $archive_member ) =~ s/obj/dep/;
							$depfile =~ s/\.o/\.d/;
							my $rmi_dependent = system("grep -q gen_inc $depfile");
						        if ( ! $rmi_dependent and ! $print_rmi_dependency ) { 
 							  print <<EOF;
build_target_source_inputs["extra_inputs"] = { PATH_ROOT .. "/itrBuild/Build/idl_inc/<extract_idl_files>" }
EOF
							  $print_rmi_dependency = 1;
							}
							&print_object_details($archive_member);
						} elsif ( $archive_member =~ /\.a$/ ) {
							$archive_member =~ s/^lib//;
							$archive_member =~ s/\.a$//;
							$build_target_lib_inputs = $build_target_lib_inputs . " -l$archive_member";
						}
					}	
				}

				print <<EOF;

-- The static libs that should be archived into this static lib.
build_target_lib_inputs = "$build_target_lib_inputs" 
table.insert( build_target_inputs, build_target_lib_inputs)

build_target_outputs = {
	build_target["location"],
	build_target["group"]
}


-- Fill the table build_target_metadata with necessary data.

build_target_metadata["build_target_inputs"] = build_target_inputs
build_target_metadata["build_target_source_inputs"] = build_target_source_inputs

build_target_metadata["build_target_outputs"] = build_target_outputs

build_target["build_target_metadata"] = build_target_metadata


EOF
			}
			if ( $file_type eq "object" ) {
				&print_object_details($input);
			}
		} else {
			print ( basename($input) . " does not exist in fsindex hash\n" );
		}
		print ("\n---------------------------------------------------------------\n");
		print ("Waiting for next input ..\n");
	}
}

sub print_object_details {
	my $obj_file = shift;
	my $obj_name;
	$obj_name = basename($obj_file);
	$obj_file = $fsindex->{"basename_to_fullpath"}->{$obj_name};
	my $obj_md5 = $fsindex->{"object"}->{"md5sum"}->{basename($obj_name)};
	$source_path = $data_struct->{"$obj_md5"}->{"source_path"};

	my $source_no_extn;
	( $source_no_extn = $source_path ) =~ s/\.[^.]+$//;


	$gen_source = qx "svn st $source_path";
	my $source_file_group;
	( my $depfile = $obj_file ) =~ s/obj/dep/;
	$depfile =~ s/\.o/\.d/;
	my $rmi_dependent = system("grep -q gen_inc $depfile");

	my $source_file_short;
	my $source_dir;
	$source_dir = dirname($source_path);
	$source_file_short = basename($source_path);

	my $replaced_path_with_var = 0;
	while ( ($var, $val) = each %$variables ) {
		chomp($var);
		chomp($val);
		( $ENV{"debug"} ) and print ("val = $val and var = $var \n");
		if ( $source_dir =~ m/$val/ and $replaced_path_with_var eq 0 ) {
			$source_dir =~ s/$val//;
			$source_path = $var . " .. \"$source_dir/$source_file_short\"";
			$replaced_path_with_var = 1;
			if ( $gen_source ) {
				$source_file_group = $var . " .. \"$source_dir/<$source_file_short>\"";
			}
		}
	}

	print <<EOF;

table.insert( build_target_source_inputs, {
	source_file = $source_path,
EOF

	( $gen_source) and print <<EOF;
	source_file_group = $source_file_group,
	generated_file = true,
EOF


	if ( $obj_name eq $source_no_extn .. ".o" ) {
		print <<EOF;
	object_file = $obj_file
EOF
	}

	if ( exists($data_struct->{"$obj_md5"}->{"compiler_flags"}) and $data_struct->{"$obj_md5"}->{"compiler_flags"} ne "" ) {
		print <<EOF;
	compiler_flags = "$data_struct->{"$obj_md5"}->{"compiler_flags"}"
EOF
	}
	print("\t}\n"); # close build_target_source_inputs's {
	print("\)\n"); # close build_target_source_inputs's {
	  
}
