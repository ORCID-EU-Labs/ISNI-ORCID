# ISNI2ORCID - linking ISNI and ORCID identifiers

Tool for searching the [ISNI registry](http://isni.org) by name and adding one or more
ISNIs to ORCID profile as as external identifiers.

This is a project by [ORCID EU labs](https://github.com/ORCID-EU-Labs/)  and [ODIN - ORCID and DataCite Interoperability Network](http://odin-project.eu).


## Background 


The application is built with the ultra-simple Ruby-based [Sinatra framework](http://www.sinatrarb.com) and relies on the
[omniauth-orcid](http://rubygems.org/gems/omniauth-orcid) gem for connecting to the ORCID registry.


## Installation

The Ruby app should work in a range of Ruby / webserver environments. We've found
a micro-virtualization and devops based environment most useful for development work.

Here's how to quickly get up and running with a local virtual box using the provided Vagrant and Chef configuration:


### Requirements

- Ruby
- git
- Vagrant: http://www.vagrantup.com
- Chef: http://www.opscode.com/chef/
- Virtualbox: https://www.virtualbox.org


### Setting up and provisioning the virtual machine

*[todo add brief note on where to get the `precise64` box to build
 from -  http://www.vagrantbox.es ]*


    git clone https://github.com/ORCID-EU-Labs/isni2orcid.git
    cd isni2orcid
    vagrant up

If you don't see any errors from the last command, you now have a properly
configured Ubuntu virtual machine running the app. You can point your browser to `http://localhost:8088` and test-drive.


*[todo: add more about installing & running]*


## License

The MIT License (OSI approved, see more at http://www.opensource.org/licenses/mit-license.php)

=============================================================================

Copyright (C) 2013 by ORCID EU

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

=============================================================================

![Open Source Initiative Approved License](http://www.opensource.org/trademarks/opensource/web/opensource-110x95.jpg)
