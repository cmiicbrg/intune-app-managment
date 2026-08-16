# Third-Party Software Notices

This project uses or references the following third-party software:

## Microsoft Win32 Content Prep Tool (IntuneWinAppUtil.exe)

- **License**: Microsoft Software License Terms
- **Source**: <https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool>
- **Usage**: Required tool (not included - users must download separately)
- **Note**: Subject to Microsoft's license terms. Users must obtain directly from Microsoft.

## Microsoft Graph PowerShell SDK (`Microsoft.Graph.Authentication`, `Microsoft.Graph.Groups`)

- **License**: MIT License
- **Copyright**: Copyright (c) Microsoft Corporation
- **Source**: <https://github.com/microsoftgraph/msgraph-sdk-powershell>
- **Usage**: `Microsoft.Graph.Authentication` is required for authentication and all Microsoft Graph API calls; `Microsoft.Graph.Groups` is used to resolve Entra ID groups for group assignments

## Historical note

Versions up to 3.1 depended on the IntuneWin32App PowerShell module (MIT License, Copyright (c) Nickolaj Andersen, <https://github.com/MSEndpointMgr/IntuneWin32App>). Since 3.2.0, all Intune API interaction is implemented natively against Microsoft Graph and that module is no longer used or installed.
