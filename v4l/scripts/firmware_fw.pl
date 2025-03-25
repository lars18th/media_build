#!/usr/bin/perl
use strict;
use warnings;
use File::Find;
use File::Spec;
use File::Basename;

# Check if the input directory is defined
if (@ARGV != 1) {
    die "Usage: $0 <firmware_directory>\n";
}

# Get the directory from ARGV[0], and ensure it's an absolute path
my $firmware_dir = File::Spec->rel2abs($ARGV[0]);

# Ensure the directory exists
unless (-d $firmware_dir) {
    die "The directory $firmware_dir does not exist or is not accessible.\n";
}

# Process .fw files
sub process_firmware_file {
    my $file = $File::Find::name;

    # Only process .fw files
    return unless $file =~ /\.fw$/;

    # Generate the absolute path of the file
    my $abs_file = File::Spec->rel2abs($file);

    # Generate the name of the .h file
    my $header_file = $file;
    $header_file =~ s/\.fw$/.h/;

    # Get just the filename (without path)
    my $filename_only = basename($file);

    # Normalize the filename to be a valid C identifier
    # Replace invalid characters (- and .) with _
    my $normalized_name = $filename_only;
    $normalized_name =~ s/[-\.]/_/g;

    # Open the .fw file for reading in binary mode
    open my $in, '<:raw', $abs_file or die "Cannot read file $abs_file: $!";
    
    # Open the corresponding .h file for writing
    open my $out, '>', $header_file or die "Cannot write to file $header_file: $!";

    # Print the header comment with only the filename
    print $out "// Automatically generated header file from $filename_only\n";
    print $out "static const unsigned char ${normalized_name}_bin[] = {\n";

    my $counter = 0;
    while (read $in, my $byte, 1) {
        # Write the data in a compact format (16 values per line)
        printf $out "0x%02x,", ord($byte);
        $counter++;
        print $out "\n" if $counter % 16 == 0; # Add a newline after every 16 values
    }

    # Ensure proper formatting by adding a newline if the last line is incomplete
    print $out "\n" if $counter % 16 != 0;

    print $out "};\n";
    print $out "static const unsigned int ${normalized_name}_bin_len = $counter;\n";

    close $in;
    close $out;

    print "Processed: $abs_file -> $header_file\n";
}

# Recursively traverse the firmware directory starting from the provided directory
find(\&process_firmware_file, $firmware_dir);

print "Conversion completed.\n";
