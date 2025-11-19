# VSCodium Remote Server for AIX

This project provides an automated build system for creating VSCodium Remote Server packages compatible with IBM AIX on ppc64 architecture.

## Project Purpose

VSCodium Remote Server does not officially support AIX. This project bridges that gap by:

1. Building native Node.js modules specifically for AIX
2. Applying necessary patches for AIX compatibility
3. Packaging the server in a format that works on AIX systems
4. Automating the entire build and release process
5. Publishing releases to GitHub for easy distribution

## Target Users

This is designed for development teams using IBM AIX systems who want to use VSCodium's remote development capabilities.

## Contributing

This is a community project. Contributions are welcome:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test on AIX
5. Submit a pull request

## Support

For issues specific to AIX builds:
- Check existing issues: https://github.com/tonykuttai/vscodium-aix-server/issues
- Create a new issue with detailed logs

For upstream VSCodium issues:
- Visit: https://github.com/VSCodium/vscodium

## License

See LICENSE file for details.

## Acknowledgments

- VSCodium project for the base remote server
- IBM for AIX platform and tools
- Open source community for native modules

## Version Information

Built for: IBM AIX 7.3 on ppc64
Node.js: 22.x
Base: VSCodium Remote Server (upstream)

Last updated: 2025-11-19