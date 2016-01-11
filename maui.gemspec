# This file is tangled from [[maui.fab]].
# Please do not edit directly.

Gem::Specification.new do |s|
  s.name = 'maui'
  s.version = '3.2.1'
  s.date = '2014-09-23'
  s.homepage = 'https://github.com/digwuren/maui'
  s.summary = 'A wiki-style literate programming engine'
  s.author = 'Andres Soolo'
  s.email = 'dig@mirky.net'
  s.files = File.read('Manifest.txt').split(/\n/)
  s.executables << 'maui'
  s.license = 'GPL-3'
  s.description = <<EOD
Fabricator is a literate programming engine with wiki-like
notation.  Mau is a PIM-oriented wiki engine built around
Fabricator.  This gem contains Maui, the Mau Independent
Fabricator, allowing Fabricator to be used via a command line
interface or via the Ruby API without a need to employ a full
installation of Mau.
EOD
  s.has_rdoc = false
end
