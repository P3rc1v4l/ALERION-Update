<#
.SYNOPSIS
    ALERION Update - WPF user interface (overview, update list with search/selection, history, settings).
.PARAMETER Monitor
    Opened by a scheduled run: shows the progress of the already running engine.
#>
[CmdletBinding()]
param(
    [switch]$Monitor,
    # Development aid: renders a page to a PNG off-screen and exits (used for design checks / docs).
    [string]$Snapshot,
    [ValidateSet('Overview', 'Updates', 'History', 'Settings')][string]$Page = 'Overview',
    [string]$Query
)

$ErrorActionPreference = 'Stop'
# Never fail silently: log unexpected GUI errors and tell the user where the log is.
trap {
    $msg = "{0:yyyy-MM-dd HH:mm:ss} {1}`n{2}" -f (Get-Date), $_.Exception.Message, $_.ScriptStackTrace
    $logDir = Join-Path $env:ProgramData 'ALERION\Update\logs'
    try { Add-Content -Path (Join-Path $logDir 'gui-error.log') -Value $msg -Encoding UTF8 } catch { }
    if (-not $Snapshot) {
        try { [void][System.Windows.MessageBox]::Show("ALERION Update: $($_.Exception.Message)`n`n$logDir\gui-error.log", 'ALERION Update', 'OK', 'Error') } catch { }
    }
    break
}
# Only load modules from admin-protected locations (see UpdateEngine.ps1).
$env:PSModulePath = "$env:ProgramFiles\WindowsPowerShell\Modules;$PSHOME\Modules"

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$src = $PSScriptRoot
Import-Module (Join-Path $src 'Common.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $src 'Report.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $src 'Scheduler.psm1') -DisableNameChecking -Force

# ------------------------------------------------------------------ elevation
if (-not (Test-IsAdmin) -and -not $Snapshot) {
    # Normally never reached: the shortcut starts the elevated GUI task. Fallback for manual starts.
    $names = Get-TaskNames
    if (Test-GuiTask) {
        & "$env:WINDIR\System32\schtasks.exe" /run /tn "$($names.Path)$($names.Gui)" | Out-Null
    } else {
        Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    }
    exit 0
}

# ------------------------------------------------------------------ single window
$showEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\ALERION-Update-GUI-Show')
$guiMutex = New-Object System.Threading.Mutex($false, 'Local\ALERION-Update-GUI')
if (-not $Snapshot -and -not $guiMutex.WaitOne(0)) { [void]$showEvent.Set(); exit 0 }

if (-not ('Alerion.UpdateRow' -as [type])) {
    Add-Type -TypeDefinition (Get-Content (Join-Path $src 'GuiModel.cs') -Raw)
}

Initialize-DataDir -Harden
[Alerion.ShellUtil]::SetProcessAppId((Get-AppUserModelId))
$config = Get-Config
Import-I18n -Language $config.Language
$paths = Get-AppPaths
$version = Get-AppVersion

# ------------------------------------------------------------------ XAML
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="ALERION Update" Width="1180" Height="760" MinWidth="980" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#111318" Foreground="#F2F3F5"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13.5" WindowStyle="None" ResizeMode="CanResize"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="40" ResizeBorderThickness="6" CornerRadius="12" GlassFrameThickness="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <sys:String x:Key="SelectAllText">Select all</sys:String>
    <SolidColorBrush x:Key="Card" Color="#1A1D24"/>
    <SolidColorBrush x:Key="CardHover" Color="#20242C"/>
    <SolidColorBrush x:Key="Line" Color="#262A33"/>
    <SolidColorBrush x:Key="Muted" Color="#8E949F"/>
    <SolidColorBrush x:Key="Blue" Color="#0A84FF"/>
    <LinearGradientBrush x:Key="Accent" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#7C3AED" Offset="0"/><GradientStop Color="#0A84FF" Offset="1"/>
    </LinearGradientBrush>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <FontFamily x:Key="Display">Segoe UI Variable Display, Segoe UI</FontFamily>

    <Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="NoWrap"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>

    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="20,9"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="b" CornerRadius="10" Background="{StaticResource Blue}" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2B95FF"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#0070E0"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Secondary" TargetType="Button">
      <Setter Property="Foreground" Value="#F2F3F5"/><Setter Property="Padding" Value="16,9"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="b" CornerRadius="10" Background="#262A33" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#30343E"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Ghost" TargetType="Button">
      <Setter Property="Foreground" Value="#8E949F"/><Setter Property="Padding" Value="8,4"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="b" CornerRadius="8" Background="Transparent" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2A2E38"/><Setter Property="Foreground" Value="#F2F3F5"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Light" TargetType="Button">
      <Setter Property="Width" Value="12"/><Setter Property="Height" Value="12"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Grid><Ellipse Fill="{TemplateBinding Background}"/>
          <TextBlock x:Name="g" Text="{TemplateBinding Content}" FontFamily="{StaticResource Icons}" FontSize="7" Foreground="#5A1A12" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Hidden"/></Grid>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="g" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#C7CBD3"/><Setter Property="Margin" Value="0,1"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
        <Border x:Name="b" CornerRadius="8" Padding="10,8" Background="Transparent"><ContentPresenter/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#22252D"/></Trigger>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="#2A2E38"/><Setter Property="Foreground" Value="White"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Segment" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#C7CBD3"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
        <Border x:Name="b" CornerRadius="7" Padding="12,5" Background="Transparent"><ContentPresenter HorizontalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="White"/></Trigger>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="#3A3F4B"/><Setter Property="Foreground" Value="White"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="SegmentBar" TargetType="Border">
      <Setter Property="Background" Value="#1F2229"/><Setter Property="CornerRadius" Value="9"/><Setter Property="Padding" Value="2"/><Setter Property="HorizontalAlignment" Value="Left"/>
    </Style>
    <Style x:Key="Toggle" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#F2F3F5"/><Setter Property="Margin" Value="0,7"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
        <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <ContentPresenter VerticalAlignment="Center" Margin="0,0,16,0"/>
          <Border x:Name="track" Grid.Column="1" Width="38" Height="22" CornerRadius="11" Background="#3A3F4B">
            <Ellipse x:Name="knob" Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="2,0"/></Border></Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="track" Property="Background" Value="#30D158"/><Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Tick" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#F2F3F5"/><Setter Property="Cursor" Value="Hand"/><Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
        <StackPanel Orientation="Horizontal">
          <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderBrush="#4A505C" BorderThickness="1.5" Background="Transparent">
            <TextBlock x:Name="mark" Text="&#xE73E;" FontFamily="{StaticResource Icons}" FontSize="11" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Hidden"/></Border>
          <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/></StackPanel>
        <ControlTemplate.Triggers>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="box" Property="Background" Value="#0A84FF"/><Setter TargetName="box" Property="BorderBrush" Value="#0A84FF"/><Setter TargetName="mark" Property="Visibility" Value="Visible"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="box" Property="Opacity" Value="0.25"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#1F2229"/><Setter Property="Foreground" Value="#F2F3F5"/><Setter Property="CaretBrush" Value="White"/>
      <Setter Property="Padding" Value="10,0"/><Setter Property="Height" Value="34"/><Setter Property="SelectionBrush" Value="#0A84FF"/><Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox">
        <Border x:Name="b" CornerRadius="9" Background="{TemplateBinding Background}" BorderBrush="#2E323C" BorderThickness="1">
          <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#0A84FF"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#F2F3F5"/><Setter Property="Padding" Value="10,6"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
        <Border x:Name="b" CornerRadius="6" Padding="{TemplateBinding Padding}" Background="Transparent"><ContentPresenter/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="b" Property="Background" Value="#0A84FF"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#F2F3F5"/><Setter Property="MinWidth" Value="200"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox">
        <Grid>
          <ToggleButton IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" Focusable="False">
            <ToggleButton.Template><ControlTemplate TargetType="ToggleButton">
              <Border CornerRadius="9" Background="#1F2229" BorderBrush="#2E323C" BorderThickness="1">
                <TextBlock Text="&#xE70D;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="9" Foreground="#8E949F" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0"/></Border>
            </ControlTemplate></ToggleButton.Template></ToggleButton>
          <ContentPresenter IsHitTestVisible="False" Margin="12,7,30,7" VerticalAlignment="Center"
            Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
          <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
            <Border Background="#24272F" BorderBrush="#343844" BorderThickness="1" CornerRadius="10" Padding="4" Margin="0,4,0,0"
                    MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="320">
              <ScrollViewer><ItemsPresenter/></ScrollViewer></Border></Popup>
        </Grid></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/><Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
        <Track x:Name="PART_Track" IsDirectionReversed="True"><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
          <Border CornerRadius="4" Background="#3A3F4B" Margin="1"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track>
      </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers><Trigger Property="Orientation" Value="Horizontal"><Setter Property="Height" Value="8"/><Setter Property="Width" Value="Auto"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track"><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
            <Border CornerRadius="4" Background="#3A3F4B" Margin="1"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track>
        </ControlTemplate></Setter.Value></Setter></Trigger></Style.Triggers>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ProgressBar">
        <Grid><Border x:Name="PART_Track" CornerRadius="3" Background="#262A33"/>
          <Border x:Name="PART_Indicator" CornerRadius="3" Background="{StaticResource Blue}" HorizontalAlignment="Left"/></Grid>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="#F2F3F5"/><Setter Property="BorderThickness" Value="0"/>
      <Setter Property="RowBackground" Value="Transparent"/><Setter Property="AlternatingRowBackground" Value="#16191F"/>
      <Setter Property="GridLinesVisibility" Value="None"/><Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="AutoGenerateColumns" Value="False"/><Setter Property="IsReadOnly" Value="True"/><Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="SelectionMode" Value="Single"/><Setter Property="RowHeight" Value="36"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="#8E949F"/><Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="12,8"/><Setter Property="BorderBrush" Value="#262A33"/><Setter Property="BorderThickness" Value="0,0,0,1"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="12,0"/><Setter Property="Foreground" Value="#F2F3F5"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="DataGridCell">
        <Border Padding="{TemplateBinding Padding}" Background="Transparent"><ContentPresenter VerticalAlignment="Center"/></Border>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="CardBorder" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Card}"/><Setter Property="CornerRadius" Value="14"/><Setter Property="Padding" Value="20"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock"><Setter Property="FontFamily" Value="{StaticResource Display}"/><Setter Property="FontSize" Value="26"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
    <Style x:Key="H2" TargetType="TextBlock"><Setter Property="FontFamily" Value="{StaticResource Display}"/><Setter Property="FontSize" Value="15"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,0,0,10"/></Style>
    <Style x:Key="Label" TargetType="TextBlock"><Setter Property="Foreground" Value="#8E949F"/><Setter Property="FontSize" Value="12"/><Setter Property="Margin" Value="0,10,0,6"/></Style>
    <Style x:Key="Hint" TargetType="TextBlock"><Setter Property="Foreground" Value="#8E949F"/><Setter Property="FontSize" Value="12"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
    <Style x:Key="Tile" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/><Setter Property="Foreground" Value="#F2F3F5"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="b" CornerRadius="14" Background="#1A1D24" Padding="18,16"><ContentPresenter/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#20242C"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Storyboard x:Key="Spin" RepeatBehavior="Forever">
      <DoubleAnimation Storyboard.TargetName="SpinRotate" Storyboard.TargetProperty="Angle" From="0" To="360" Duration="0:0:0.9"/>
    </Storyboard>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="232"/><ColumnDefinition/></Grid.ColumnDefinitions>

    <!-- Sidebar -->
    <Border Background="#17191F" BorderBrush="#22252C" BorderThickness="0,0,1,0">
      <DockPanel Margin="14,14,14,14" LastChildFill="False">
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="4,0,0,22">
          <Button x:Name="BtnClose" Style="{StaticResource Light}" Background="#FF5F57" Content="&#xE8BB;"/>
          <Button x:Name="BtnMin" Style="{StaticResource Light}" Background="#FEBC2E" Content="&#xE921;"/>
          <Button x:Name="BtnMax" Style="{StaticResource Light}" Background="#28C840" Content="&#xE740;"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="6,0,0,22">
          <Image x:Name="Logo" Width="34" Height="34"/>
          <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="ALERION Update" FontWeight="SemiBold" FontSize="14" Foreground="White"/>
            <TextBlock x:Name="TxtSidebarSub" FontSize="11.5" Foreground="#8E949F"/>
          </StackPanel>
        </StackPanel>
        <RadioButton x:Name="NavOverview" DockPanel.Dock="Top" Style="{StaticResource Nav}" GroupName="nav" IsChecked="True">
          <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE80F;" FontFamily="{StaticResource Icons}" Margin="0,2,12,0" Foreground="#0A84FF"/><TextBlock x:Name="TxtNavOverview"/></StackPanel></RadioButton>
        <RadioButton x:Name="NavUpdates" DockPanel.Dock="Top" Style="{StaticResource Nav}" GroupName="nav">
          <Grid><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE896;" FontFamily="{StaticResource Icons}" Margin="0,2,12,0" Foreground="#0A84FF"/><TextBlock x:Name="TxtNavUpdates"/></StackPanel>
            <Border x:Name="Badge" HorizontalAlignment="Right" CornerRadius="9" Background="#FF453A" Padding="7,1" Margin="0,0,-2,0" Visibility="Collapsed">
              <TextBlock x:Name="TxtBadge" FontSize="11" FontWeight="SemiBold" Foreground="White"/></Border></Grid></RadioButton>
        <RadioButton x:Name="NavHistory" DockPanel.Dock="Top" Style="{StaticResource Nav}" GroupName="nav">
          <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE81C;" FontFamily="{StaticResource Icons}" Margin="0,2,12,0" Foreground="#0A84FF"/><TextBlock x:Name="TxtNavHistory"/></StackPanel></RadioButton>

        <StackPanel DockPanel.Dock="Bottom">
          <RadioButton x:Name="NavSettings" Style="{StaticResource Nav}" GroupName="nav">
            <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE713;" FontFamily="{StaticResource Icons}" Margin="0,2,12,0" Foreground="#8E949F"/><TextBlock x:Name="TxtNavSettings"/></StackPanel></RadioButton>
          <TextBlock x:Name="TxtVersion" Foreground="#5E6470" FontSize="11" Margin="10,10,0,0"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- Content -->
    <Grid Grid.Column="1" Margin="0,40,0,0">

      <!-- Overview -->
      <ScrollViewer x:Name="PageOverview" VerticalScrollBarVisibility="Auto" Padding="32,0,32,28">
        <StackPanel>
          <Border CornerRadius="18" Padding="28,26">
            <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#231C3D" Offset="0"/><GradientStop Color="#102A44" Offset="1"/></LinearGradientBrush></Border.Background>
            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Grid Width="54" Height="54" Margin="0,0,20,0" VerticalAlignment="Center">
                <Ellipse x:Name="StateCircle" Fill="#30D158" Opacity="0.18"/>
                <TextBlock x:Name="StateGlyph" Text="&#xE73E;" FontFamily="{StaticResource Icons}" FontSize="22" Foreground="#30D158" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                <Path x:Name="Spinner" Data="M 27,4 A 23,23 0 0 1 50,27" Stroke="#0A84FF" StrokeThickness="3.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Visibility="Collapsed" RenderTransformOrigin="0.5,0.5">
                  <Path.RenderTransform><RotateTransform x:Name="SpinRotate"/></Path.RenderTransform></Path>
              </Grid>
              <StackPanel Grid.Column="1" VerticalAlignment="Center">
                <TextBlock x:Name="TxtState" Style="{StaticResource H1}" Foreground="White"/>
                <TextBlock x:Name="TxtSub" Foreground="#A9AFBC" Margin="0,4,0,0"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnScan" Style="{StaticResource Secondary}" Margin="0,0,10,0"/>
                <Button x:Name="BtnCancel" Style="{StaticResource Secondary}" Margin="0,0,10,0" Visibility="Collapsed"/>
                <Button x:Name="BtnRecommended" Style="{StaticResource Primary}"/>
              </StackPanel>
            </Grid>
          </Border>

          <StackPanel x:Name="ProgressPanel" Margin="4,16,4,0" Visibility="Collapsed">
            <Grid><TextBlock x:Name="TxtCurrent" Foreground="#C7CBD3" Margin="0,0,60,0"/>
              <TextBlock x:Name="TxtPercent" HorizontalAlignment="Right" Foreground="#8E949F"/></Grid>
            <ProgressBar x:Name="Progress" Margin="0,8,0,0" Maximum="100"/>
          </StackPanel>

          <Border x:Name="RebootBanner" Margin="0,16,0,0" CornerRadius="12" Padding="16,10" Background="#2B2412" Visibility="Collapsed">
            <Grid><StackPanel Orientation="Horizontal" VerticalAlignment="Center"><TextBlock Text="&#xE7BA;" FontFamily="{StaticResource Icons}" Foreground="#FF9F0A" Margin="0,2,10,0"/>
              <TextBlock x:Name="TxtRebootBanner" Foreground="#FFD60A"/></StackPanel>
              <Button x:Name="BtnRestart" Style="{StaticResource Secondary}" HorizontalAlignment="Right" Padding="14,6"/></Grid>
          </Border>

          <UniformGrid Columns="4" Margin="-6,16,-6,0">
            <Button x:Name="TileCritical" Style="{StaticResource Tile}" Margin="6"><StackPanel>
              <StackPanel Orientation="Horizontal"><Ellipse Width="8" Height="8" Fill="#FF453A" Margin="0,0,8,0"/><TextBlock x:Name="LblTileCritical" Foreground="#8E949F" FontSize="12"/></StackPanel>
              <TextBlock x:Name="TxtTileCritical" FontFamily="{StaticResource Display}" FontSize="30" FontWeight="SemiBold" Margin="0,6,0,0"/></StackPanel></Button>
            <Button x:Name="TileImportant" Style="{StaticResource Tile}" Margin="6"><StackPanel>
              <StackPanel Orientation="Horizontal"><Ellipse Width="8" Height="8" Fill="#FF9F0A" Margin="0,0,8,0"/><TextBlock x:Name="LblTileImportant" Foreground="#8E949F" FontSize="12"/></StackPanel>
              <TextBlock x:Name="TxtTileImportant" FontFamily="{StaticResource Display}" FontSize="30" FontWeight="SemiBold" Margin="0,6,0,0"/></StackPanel></Button>
            <Button x:Name="TileNormal" Style="{StaticResource Tile}" Margin="6"><StackPanel>
              <StackPanel Orientation="Horizontal"><Ellipse Width="8" Height="8" Fill="#0A84FF" Margin="0,0,8,0"/><TextBlock x:Name="LblTileNormal" Foreground="#8E949F" FontSize="12"/></StackPanel>
              <TextBlock x:Name="TxtTileNormal" FontFamily="{StaticResource Display}" FontSize="30" FontWeight="SemiBold" Margin="0,6,0,0"/></StackPanel></Button>
            <Button x:Name="TileOptional" Style="{StaticResource Tile}" Margin="6"><StackPanel>
              <StackPanel Orientation="Horizontal"><Ellipse Width="8" Height="8" Fill="#8E8E93" Margin="0,0,8,0"/><TextBlock x:Name="LblTileOptional" Foreground="#8E949F" FontSize="12"/></StackPanel>
              <TextBlock x:Name="TxtTileOptional" FontFamily="{StaticResource Display}" FontSize="30" FontWeight="SemiBold" Margin="0,6,0,0"/></StackPanel></Button>
          </UniformGrid>

          <UniformGrid Columns="3" Margin="-6,4,-6,0">
            <Border Style="{StaticResource CardBorder}" Margin="6"><StackPanel><TextBlock x:Name="LblLastScan" Style="{StaticResource Label}" Margin="0,0,0,4"/><TextBlock x:Name="TxtLastScan" FontSize="14.5" FontWeight="SemiBold"/></StackPanel></Border>
            <Border Style="{StaticResource CardBorder}" Margin="6"><StackPanel><TextBlock x:Name="LblLastRun" Style="{StaticResource Label}" Margin="0,0,0,4"/><TextBlock x:Name="TxtLastRun" FontSize="14.5" FontWeight="SemiBold"/></StackPanel></Border>
            <Border Style="{StaticResource CardBorder}" Margin="6"><StackPanel><TextBlock x:Name="LblNext" Style="{StaticResource Label}" Margin="0,0,0,4"/><TextBlock x:Name="TxtNext" FontSize="14.5" FontWeight="SemiBold"/></StackPanel></Border>
          </UniformGrid>

          <Border Style="{StaticResource CardBorder}" Margin="0,10,0,0" Padding="18,14">
            <StackPanel>
              <Grid><TextBlock x:Name="LblLog" Style="{StaticResource H2}" Margin="0"/>
                <Button x:Name="BtnToggleLog" Style="{StaticResource Ghost}" HorizontalAlignment="Right"/></Grid>
              <ListBox x:Name="LogList" Background="Transparent" BorderThickness="0" Foreground="#A9AFBC" FontFamily="Cascadia Mono, Consolas" FontSize="11.5"
                       Height="200" Margin="0,10,0,0" Visibility="Collapsed" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- Updates -->
      <Grid x:Name="PageUpdates" Visibility="Collapsed" Margin="32,0,32,0">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Grid>
          <StackPanel><TextBlock x:Name="TxtUpdatesTitle" Style="{StaticResource H1}"/><TextBlock x:Name="TxtUpdatesSub" Foreground="#8E949F" Margin="0,2,0,0"/></StackPanel>
          <Grid HorizontalAlignment="Right" Width="300" VerticalAlignment="Center">
            <TextBox x:Name="TxtSearch" Padding="32,0,10,0" Height="38"/>
            <TextBlock Text="&#xE721;" FontFamily="{StaticResource Icons}" Foreground="#8E949F" Margin="12,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            <TextBlock x:Name="TxtSearchHint" Foreground="#6B717D" Margin="34,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
          </Grid>
        </Grid>
        <Border Grid.Row="1" Style="{StaticResource SegmentBar}" Margin="0,16,0,10">
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="SegAll" Style="{StaticResource Segment}" GroupName="seg" IsChecked="True"/>
            <RadioButton x:Name="SegCritical" Style="{StaticResource Segment}" GroupName="seg"/>
            <RadioButton x:Name="SegImportant" Style="{StaticResource Segment}" GroupName="seg"/>
            <RadioButton x:Name="SegNormal" Style="{StaticResource Segment}" GroupName="seg"/>
            <RadioButton x:Name="SegOptional" Style="{StaticResource Segment}" GroupName="seg"/>
            <RadioButton x:Name="SegExcluded" Style="{StaticResource Segment}" GroupName="seg"/>
            <RadioButton x:Name="SegInstalled" Style="{StaticResource Segment}" GroupName="seg"/>
          </StackPanel>
        </Border>
        <Grid Grid.Row="2">
          <ListBox x:Name="UpdateList" Background="Transparent" BorderThickness="0" Foreground="#F2F3F5" HorizontalContentAlignment="Stretch"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled" VirtualizingPanel.IsVirtualizingWhenGrouping="True" VirtualizingPanel.ScrollUnit="Pixel">
            <ListBox.ItemContainerStyle>
              <Style TargetType="ListBoxItem">
                <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
                  <Border x:Name="b" CornerRadius="10" Padding="12,9" Margin="0,1" Background="Transparent"><ContentPresenter/></Border>
                  <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1A1D24"/></Trigger></ControlTemplate.Triggers>
                </ControlTemplate></Setter.Value></Setter>
              </Style>
            </ListBox.ItemContainerStyle>
            <ListBox.GroupStyle>
              <GroupStyle>
                <GroupStyle.HeaderTemplate><DataTemplate>
                  <Grid Margin="12,14,12,4">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="12.5" Foreground="#C7CBD3"/>
                      <TextBlock Text="{Binding ItemCount}" Foreground="#6B717D" FontSize="12.5" Margin="8,0,0,0"/>
                    </StackPanel>
                    <Button x:Name="GroupSelect" Tag="{Binding Name}" HorizontalAlignment="Right" Padding="8,2" FontSize="12" Foreground="#0A84FF" Content="{DynamicResource SelectAllText}">
                      <Button.Style><Style TargetType="Button" BasedOn="{StaticResource Ghost}">
                        <Style.Triggers><DataTrigger Binding="{Binding Items[0].Selectable}" Value="False"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger></Style.Triggers></Style></Button.Style>
                    </Button>
                  </Grid>
                </DataTemplate></GroupStyle.HeaderTemplate>
              </GroupStyle>
            </ListBox.GroupStyle>
            <ListBox.ItemTemplate><DataTemplate>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition/><ColumnDefinition Width="230"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="104"/><ColumnDefinition Width="36"/></Grid.ColumnDefinitions>
                <CheckBox IsChecked="{Binding Selected, Mode=TwoWay}" IsEnabled="{Binding Selectable}">
                  <CheckBox.Style><Style TargetType="CheckBox" BasedOn="{StaticResource Tick}">
                    <Style.Triggers><DataTrigger Binding="{Binding IsUpdate}" Value="False"><Setter Property="Visibility" Value="Hidden"/></DataTrigger></Style.Triggers></Style></CheckBox.Style>
                </CheckBox>
                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,12,0">
                  <TextBlock Text="{Binding Name}" FontWeight="SemiBold"/>
                  <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
                    <TextBlock Text="{Binding SourceLabel}" Foreground="#6B717D" FontSize="11.5"/>
                    <TextBlock Text="  &#x00B7;  " Foreground="#6B717D" FontSize="11.5"/>
                    <TextBlock Text="{Binding Id}" Foreground="#6B717D" FontSize="11.5" MaxWidth="320"/>
                    <TextBlock Text="{Binding Note}" Foreground="#8E949F" FontSize="11.5" Margin="10,0,0,0" MaxWidth="320"/>
                  </StackPanel>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="{Binding From}" Foreground="#8E949F" FontFamily="Cascadia Mono, Consolas" FontSize="12" MaxWidth="100"/>
                  <TextBlock Text="  &#x2192;  " Foreground="#6B717D" FontSize="12"><TextBlock.Style><Style TargetType="TextBlock"><Style.Triggers><DataTrigger Binding="{Binding ShowArrow}" Value="False"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger></Style.Triggers></Style></TextBlock.Style></TextBlock>
                  <TextBlock Text="{Binding To}" Foreground="#F2F3F5" FontFamily="Cascadia Mono, Consolas" FontSize="12" MaxWidth="100"/>
                </StackPanel>
                <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,10,0">
                  <Border CornerRadius="6" Padding="7,2" Background="#2B2412" Margin="0,0,6,0">
                    <Border.Style><Style TargetType="Border"><Setter Property="Visibility" Value="Collapsed"/>
                      <Style.Triggers><DataTrigger Binding="{Binding Major}" Value="True"><Setter Property="Visibility" Value="Visible"/></DataTrigger></Style.Triggers></Style></Border.Style>
                    <TextBlock Text="{Binding MajorLabel}" Foreground="#FF9F0A" FontSize="11"/></Border>
                  <Border CornerRadius="6" Padding="7,2" Background="#22252D">
                    <Border.Style><Style TargetType="Border"><Style.Triggers><DataTrigger Binding="{Binding IsUpdate}" Value="False"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger></Style.Triggers></Style></Border.Style>
                    <StackPanel Orientation="Horizontal"><Ellipse Width="6" Height="6" Fill="{Binding PriorityBrush}" Margin="0,0,6,0"/>
                      <TextBlock Text="{Binding PriorityLabel}" Foreground="#C7CBD3" FontSize="11"/></StackPanel></Border>
                </StackPanel>
                <TextBlock Grid.Column="4" Text="{Binding StateText}" Foreground="{Binding StateBrush}" FontSize="12" FontWeight="SemiBold" VerticalAlignment="Center"/>
                <Button x:Name="ExcludeBtn" Grid.Column="5" Content="{Binding ExcludeGlyph}" ToolTip="{Binding ExcludeTip}"
                        FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13" Padding="7,5">
                  <Button.Style><Style TargetType="Button" BasedOn="{StaticResource Ghost}">
                    <Style.Triggers><DataTrigger Binding="{Binding CanExclude}" Value="False"><Setter Property="Visibility" Value="Hidden"/></DataTrigger></Style.Triggers></Style></Button.Style>
                </Button>
              </Grid>
            </DataTemplate></ListBox.ItemTemplate>
          </ListBox>
          <StackPanel x:Name="EmptyPanel" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed">
            <TextBlock x:Name="EmptyGlyph" Text="&#xE73E;" FontFamily="{StaticResource Icons}" FontSize="36" Foreground="#30D158" HorizontalAlignment="Center"/>
            <TextBlock x:Name="TxtEmpty" Foreground="#8E949F" Margin="0,12,0,0" HorizontalAlignment="Center" TextWrapping="Wrap" TextAlignment="Center" MaxWidth="420"/>
          </StackPanel>
        </Grid>
        <Border Grid.Row="3" Margin="-32,0,-32,0" Padding="32,12" Background="#15171C" BorderBrush="#22252C" BorderThickness="0,1,0,0">
          <Grid>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock x:Name="TxtSelected" Foreground="#C7CBD3" VerticalAlignment="Center"/>
              <Button x:Name="BtnSelectNone" Style="{StaticResource Ghost}" Margin="12,0,0,0" Foreground="#0A84FF"/>
            </StackPanel>
            <Button x:Name="BtnInstallSelected" Style="{StaticResource Primary}" HorizontalAlignment="Right"/>
          </Grid>
        </Border>
      </Grid>

      <!-- History -->
      <Grid x:Name="PageHistory" Visibility="Collapsed" Margin="32,0,32,28">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition/></Grid.RowDefinitions>
        <Grid.ColumnDefinitions><ColumnDefinition Width="250"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <StackPanel Grid.ColumnSpan="2" Margin="0,0,0,16"><TextBlock x:Name="TxtHistoryTitle" Style="{StaticResource H1}"/><TextBlock x:Name="TxtRepMeta" Foreground="#8E949F" Margin="0,2,0,0"/></StackPanel>
        <StackPanel Grid.ColumnSpan="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Button x:Name="BtnLogs" Style="{StaticResource Secondary}" Margin="0,0,10,0"/><Button x:Name="BtnHtml" Style="{StaticResource Secondary}"/></StackPanel>
        <ListBox x:Name="ReportList" Grid.Row="1" Background="Transparent" BorderThickness="0" Foreground="#F2F3F5" Margin="0,0,14,0" HorizontalContentAlignment="Stretch">
          <ListBox.ItemContainerStyle><Style TargetType="ListBoxItem">
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
              <Border x:Name="b" CornerRadius="10" Padding="12,9" Margin="0,1" Background="Transparent"><ContentPresenter/></Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1A1D24"/></Trigger>
                <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="#24324A"/></Trigger>
              </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style></ListBox.ItemContainerStyle>
          <ListBox.ItemTemplate><DataTemplate><StackPanel>
            <TextBlock Text="{Binding Title}" FontWeight="SemiBold"/><TextBlock Text="{Binding Subtitle}" Foreground="#8E949F" FontSize="12" Margin="0,2,0,0"/>
          </StackPanel></DataTemplate></ListBox.ItemTemplate>
        </ListBox>
        <TextBlock x:Name="TxtHistoryEmpty" Grid.Row="1" Grid.ColumnSpan="2" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#8E949F" Visibility="Collapsed"/>
        <Border x:Name="HistoryCard" Grid.Row="1" Grid.Column="1" Style="{StaticResource CardBorder}" Padding="6">
          <DataGrid x:Name="Grid">
            <DataGrid.Columns>
              <DataGridTextColumn x:Name="ColSource" Binding="{Binding Source}" Width="100"/>
              <DataGridTextColumn x:Name="ColName" Binding="{Binding Name}" Width="2*"/>
              <DataGridTextColumn x:Name="ColFrom" Binding="{Binding From}" Width="*" FontFamily="Cascadia Mono, Consolas"/>
              <DataGridTextColumn x:Name="ColTo" Binding="{Binding To}" Width="*" FontFamily="Cascadia Mono, Consolas"/>
              <DataGridTemplateColumn x:Name="ColStatus" Width="120"><DataGridTemplateColumn.CellTemplate><DataTemplate>
                <TextBlock Text="{Binding StatusText}" Foreground="{Binding StatusColor}" FontWeight="SemiBold"/></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn>
              <DataGridTextColumn x:Name="ColNote" Binding="{Binding Note}" Width="2*" Foreground="#8E949F"/>
            </DataGrid.Columns>
          </DataGrid>
        </Border>
      </Grid>

      <!-- Settings -->
      <ScrollViewer x:Name="PageSettings" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,0,24,28">
        <StackPanel MaxWidth="760" HorizontalAlignment="Left">
          <Grid Margin="0,0,0,16"><TextBlock x:Name="TxtSettingsTitle" Style="{StaticResource H1}"/>
            <TextBlock x:Name="TxtSaved" Foreground="#30D158" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>

          <Border Style="{StaticResource CardBorder}" Margin="0,0,0,12"><StackPanel>
            <TextBlock x:Name="LblAuto" Style="{StaticResource H2}"/>
            <WrapPanel>
              <StackPanel Margin="0,0,16,0"><TextBlock x:Name="LblSchType" Style="{StaticResource Label}"/><ComboBox x:Name="CmbSchedule"/></StackPanel>
              <StackPanel x:Name="PnlDay" Margin="0,0,16,0"><TextBlock x:Name="LblDay" Style="{StaticResource Label}"/><ComboBox x:Name="CmbDay" MinWidth="160"/></StackPanel>
              <StackPanel x:Name="PnlDom" Margin="0,0,16,0"><TextBlock x:Name="LblDom" Style="{StaticResource Label}"/><ComboBox x:Name="CmbDom" MinWidth="100"/></StackPanel>
              <StackPanel x:Name="PnlTime"><TextBlock x:Name="LblTime" Style="{StaticResource Label}"/><TextBox x:Name="TxtTime" Width="100"/></StackPanel>
            </WrapPanel>
            <StackPanel x:Name="PnlAutoDetails">
              <TextBlock x:Name="LblAction" Style="{StaticResource Label}" Margin="0,16,0,6"/>
              <Border Style="{StaticResource SegmentBar}"><StackPanel Orientation="Horizontal">
                <RadioButton x:Name="RbActInstall" Style="{StaticResource Segment}" GroupName="act"/>
                <RadioButton x:Name="RbActNotify" Style="{StaticResource Segment}" GroupName="act"/></StackPanel></Border>
              <StackPanel x:Name="PnlAutoPrio">
                <TextBlock x:Name="LblAutoPrio" Style="{StaticResource Label}" Margin="0,16,0,8"/>
                <WrapPanel>
                  <CheckBox x:Name="ChkPrioCritical" Style="{StaticResource Tick}" Margin="0,0,22,0"/>
                  <CheckBox x:Name="ChkPrioImportant" Style="{StaticResource Tick}" Margin="0,0,22,0"/>
                  <CheckBox x:Name="ChkPrioNormal" Style="{StaticResource Tick}" Margin="0,0,22,0"/>
                  <CheckBox x:Name="ChkPrioOptional" Style="{StaticResource Tick}"/>
                </WrapPanel>
              </StackPanel>
              <CheckBox x:Name="ChkWake" Style="{StaticResource Toggle}" Margin="0,16,0,0"/>
            </StackPanel>
          </StackPanel></Border>

          <Border Style="{StaticResource CardBorder}" Margin="0,0,0,12"><StackPanel>
            <TextBlock x:Name="LblBehavior" Style="{StaticResource H2}"/>
            <TextBlock x:Name="LblMode2" Style="{StaticResource Label}" Margin="0,0,0,6"/>
            <Border Style="{StaticResource SegmentBar}"><StackPanel Orientation="Horizontal">
              <RadioButton x:Name="RbVisible" Style="{StaticResource Segment}" GroupName="mode"/>
              <RadioButton x:Name="RbSilent" Style="{StaticResource Segment}" GroupName="mode"/></StackPanel></Border>
            <CheckBox x:Name="ChkParallel" Style="{StaticResource Toggle}" Margin="0,14,0,0"/>
            <CheckBox x:Name="ChkRestore" Style="{StaticResource Toggle}"/>
            <Grid Margin="0,6,0,0"><TextBlock x:Name="LblReboot" VerticalAlignment="Center"/><ComboBox x:Name="CmbReboot" HorizontalAlignment="Right" MinWidth="240"/></Grid>
            <Grid Margin="0,10,0,0"><TextBlock x:Name="LblLang" VerticalAlignment="Center"/><ComboBox x:Name="CmbLang" HorizontalAlignment="Right" MinWidth="240"/></Grid>
          </StackPanel></Border>

          <Border Style="{StaticResource CardBorder}" Margin="0,0,0,12"><StackPanel>
            <TextBlock x:Name="LblSources" Style="{StaticResource H2}"/>
            <StackPanel x:Name="SourcePanel"/>
          </StackPanel></Border>

          <Border Style="{StaticResource CardBorder}" Margin="0,0,0,12"><StackPanel>
            <TextBlock x:Name="LblExcl" Style="{StaticResource H2}"/>
            <TextBlock x:Name="TxtExclHint" Style="{StaticResource Hint}" Margin="0,0,0,10"/>
            <ItemsControl x:Name="ExclChips">
              <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
              <ItemsControl.ItemTemplate><DataTemplate>
                <Border CornerRadius="8" Background="#262A33" Padding="10,4,4,4" Margin="0,0,8,8">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="{Binding}" FontFamily="Cascadia Mono, Consolas" FontSize="12" VerticalAlignment="Center"/>
                    <Button x:Name="ChipRemove" Tag="{Binding}" Style="{StaticResource Ghost}" Content="&#xE711;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="9" Padding="6,4" Margin="4,0,0,0"/></StackPanel>
                </Border></DataTemplate></ItemsControl.ItemTemplate>
            </ItemsControl>
            <Grid Margin="0,4,0,0"><TextBox x:Name="TxtExclAdd" Margin="0,0,120,0" FontFamily="Cascadia Mono, Consolas"/>
              <Button x:Name="BtnExclAdd" Style="{StaticResource Secondary}" HorizontalAlignment="Right" Width="110"/></Grid>
          </StackPanel></Border>

          <Border Style="{StaticResource CardBorder}" Margin="0,0,0,12"><StackPanel>
            <TextBlock x:Name="LblSelf" Style="{StaticResource H2}"/>
            <TextBlock x:Name="TxtSelfStatus" Style="{StaticResource Hint}" Margin="0,0,0,6"/>
            <CheckBox x:Name="ChkSelf" Style="{StaticResource Toggle}"/>
            <TextBlock x:Name="LblRepo" Style="{StaticResource Label}"/><TextBox x:Name="TxtRepo" Width="320" HorizontalAlignment="Left"/>
          </StackPanel></Border>
        </StackPanel>
      </ScrollViewer>
    </Grid>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $n = $_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
    if ($n) { $el = $window.FindName($n.Value); if ($el) { $ui[$n.Value] = $el } }
}
if (Test-Path $paths.IconPath) { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([uri]$paths.IconPath) }
if (Test-Path $paths.LogoPath) { $ui.Logo.Source = [Windows.Media.Imaging.BitmapImage]::new([uri]$paths.LogoPath) }
$window.Add_SourceInitialized({ [Alerion.ShellUtil]::StyleWindow((New-Object System.Windows.Interop.WindowInteropHelper $window).Handle) })

# ------------------------------------------------------------------ state
$prioColors  = @{ Critical = '#FF453A'; Important = '#FF9F0A'; Normal = '#0A84FF'; Optional = '#8E8E93' }
$prioRank    = @{ Critical = 0; Important = 1; Normal = 2; Optional = 3 }
$stateColors = @{ Pending = '#8E949F'; Running = '#0A84FF'; Done = '#30D158'; Failed = '#FF453A'; Skipped = '#8E949F'; Current = '#30D158' }
$statusColors = @{ Updated = '#30D158'; Failed = '#FF453A'; Skipped = '#8E949F'; Info = '#8E949F'; Available = '#0A84FF'; Triggered = '#0A84FF' }
$rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[Alerion.UpdateRow]'
$view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($rows)
$ui.UpdateList.ItemsSource = $rows
$script:segment = 'All'
$script:search = ''
$script:running = $false
$script:runMode = ''
$script:loading = $false
$script:scanAt = $null
$script:wasRunning = $false
$sourceKeys = @('Winget', 'WingetIncludeUnknown', 'Chocolatey', 'Store', 'WindowsUpdate', 'WindowsUpdateDrivers', 'MicrosoftUpdate', 'Nvidia', 'Defender', 'Office')
$sourceBoxes = @{}

$brushConverter = New-Object System.Windows.Media.BrushConverter
function Get-Brush { param([string]$Hex) $brushConverter.ConvertFromString($Hex) }
function New-ComboItem { param($Tag, $Text) $i = New-Object System.Windows.Controls.ComboBoxItem; $i.Tag = $Tag; $i.Content = $Text; $i }
function Select-ComboTag { param($Combo, $Tag) foreach ($i in $Combo.Items) { if ([string]$i.Tag -eq [string]$Tag) { $Combo.SelectedItem = $i; return } }; if ($Combo.Items.Count) { $Combo.SelectedIndex = 0 } }
function Format-When { param($Date)
    if (-not $Date) { return (T 'ov.never') }
    $d = [datetime]$Date; $span = (Get-Date) - $d
    if ($span.TotalMinutes -lt 1) { return (T 'time.justNow') }
    if ($span.TotalMinutes -lt 60) { return (T 'time.minutesAgo' @([int]$span.TotalMinutes)) }
    if ($d.Date -eq (Get-Date).Date) { return (T 'time.todayAt' @($d.ToString('HH:mm'))) }
    return $d.ToString('ddd, dd.MM.  HH:mm')
}

# ------------------------------------------------------------------ texts
function Set-Texts {
    $ui.TxtNavOverview.Text = T 'nav.overview'; $ui.TxtNavUpdates.Text = T 'nav.updates'; $ui.TxtNavHistory.Text = T 'nav.history'
    $ui.TxtNavSettings.Text = T 'nav.settings'; $ui.TxtSidebarSub.Text = T 'app.subtitle'; $ui.TxtVersion.Text = "Version $version"
    $ui.BtnClose.ToolTip = T 'win.close'; $ui.BtnMin.ToolTip = T 'win.minimize'; $ui.BtnMax.ToolTip = T 'win.maximize'
    $ui.BtnScan.Content = T 'ov.scan'; $ui.BtnCancel.Content = T 'ov.cancel'; $ui.BtnRestart.Content = T 'ov.restartNow'
    $ui.TxtRebootBanner.Text = T 'ov.rebootPending'
    foreach ($p in 'Critical', 'Important', 'Normal', 'Optional') { $ui["LblTile$p"].Text = T "prio.$p" }
    $ui.LblLastScan.Text = T 'ov.lastScan'; $ui.LblLastRun.Text = T 'ov.lastRun'; $ui.LblNext.Text = T 'ov.nextRun'
    $ui.LblLog.Text = T 'ov.log'; $ui.BtnToggleLog.Content = if ($ui.LogList.Visibility -eq 'Visible') { T 'ov.hideLog' } else { T 'ov.showLog' }
    $ui.TxtUpdatesTitle.Text = T 'nav.updates'; $ui.TxtSearchHint.Text = T 'up.search'
    $ui.SegAll.Content = T 'seg.all'; $ui.SegCritical.Content = T 'prio.Critical'; $ui.SegImportant.Content = T 'prio.Important'
    $ui.SegNormal.Content = T 'prio.Normal'; $ui.SegOptional.Content = T 'prio.Optional'; $ui.SegExcluded.Content = T 'seg.excluded'; $ui.SegInstalled.Content = T 'seg.installed'
    $ui.BtnSelectNone.Content = T 'up.selectNone'; $window.Resources['SelectAllText'] = T 'up.selectAll'
    $ui.TxtHistoryTitle.Text = T 'nav.history'; $ui.BtnHtml.Content = T 'rep.openHtml'; $ui.BtnLogs.Content = T 'rep.openLogs'
    $ui.ColSource.Header = T 'rep.colSource'; $ui.ColName.Header = T 'rep.colName'; $ui.ColFrom.Header = T 'rep.colFrom'
    $ui.ColTo.Header = T 'rep.colTo'; $ui.ColStatus.Header = T 'rep.colStatus'; $ui.ColNote.Header = T 'rep.colNote'
    $ui.TxtSettingsTitle.Text = T 'nav.settings'
    $ui.LblAuto.Text = T 'set.auto'; $ui.LblSchType.Text = T 'set.scheduleType'; $ui.LblDay.Text = T 'set.day'; $ui.LblDom.Text = T 'set.dayOfMonth'
    $ui.LblTime.Text = T 'set.time'; $ui.LblAction.Text = T 'set.action'; $ui.RbActInstall.Content = T 'set.act.Install'; $ui.RbActNotify.Content = T 'set.act.Notify'
    $ui.LblAutoPrio.Text = T 'set.autoPrio'
    foreach ($p in 'Critical', 'Important', 'Normal', 'Optional') { $ui["ChkPrio$p"].Content = T "prio.$p" }
    $ui.ChkWake.Content = T 'set.wake'
    $ui.LblBehavior.Text = T 'set.behavior'; $ui.LblMode2.Text = T 'set.mode'; $ui.RbVisible.Content = T 'set.mode.Visible'; $ui.RbSilent.Content = T 'set.mode.Silent'
    $ui.ChkParallel.Content = T 'set.parallel'; $ui.ChkRestore.Content = T 'set.restore'; $ui.LblReboot.Text = T 'set.reboot'; $ui.LblLang.Text = T 'set.language'
    $ui.LblSources.Text = T 'set.sources'; $ui.LblExcl.Text = T 'set.exclusions'; $ui.TxtExclHint.Text = T 'set.exclHint'; $ui.BtnExclAdd.Content = T 'set.exclAdd'
    $ui.LblSelf.Text = T 'set.selfTitle'; $ui.ChkSelf.Content = T 'set.selfUpdate'; $ui.LblRepo.Text = T 'set.selfRepo'
    foreach ($k in $sourceKeys) { $sourceBoxes[$k].Content = T "set.src.$k" }

    $script:loading = $true
    $ui.CmbSchedule.Items.Clear(); foreach ($s in 'Manual', 'Daily', 'Weekly', 'BiWeekly', 'Monthly') { [void]$ui.CmbSchedule.Items.Add((New-ComboItem $s (T "set.sch.$s"))) }
    $ui.CmbReboot.Items.Clear(); foreach ($s in 'Prompt', 'Never', 'Auto') { [void]$ui.CmbReboot.Items.Add((New-ComboItem $s (T "set.reboot.$s"))) }
    $culture = if ((Get-CurrentLanguage) -eq 'de') { [Globalization.CultureInfo]'de-DE' } else { [Globalization.CultureInfo]'en-US' }
    $ui.CmbDay.Items.Clear(); foreach ($d in 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday') {
        [void]$ui.CmbDay.Items.Add((New-ComboItem $d $culture.DateTimeFormat.GetDayName([DayOfWeek]$d))) }
    $script:loading = $false
}

function Initialize-Controls {
    foreach ($k in $sourceKeys) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $window.FindResource('Toggle')
        if ($k -in 'WingetIncludeUnknown', 'WindowsUpdateDrivers', 'MicrosoftUpdate') { $cb.Margin = [System.Windows.Thickness]::new(24, 7, 0, 7); $cb.Foreground = Get-Brush '#C7CBD3' }
        $sourceBoxes[$k] = $cb; [void]$ui.SourcePanel.Children.Add($cb)
        $cb.Add_Click({ Save-Settings })
    }
    $ui.CmbDom.Items.Clear(); 1..28 | ForEach-Object { [void]$ui.CmbDom.Items.Add((New-ComboItem $_ "$_.")) }
    $ui.CmbLang.Items.Clear(); [void]$ui.CmbLang.Items.Add((New-ComboItem 'de' 'Deutsch')); [void]$ui.CmbLang.Items.Add((New-ComboItem 'en' 'English'))
}

# ------------------------------------------------------------------ settings (saved automatically)
function Show-Config {
    $script:loading = $true
    Select-ComboTag $ui.CmbSchedule $config.Schedule.Type
    Select-ComboTag $ui.CmbDay $config.Schedule.DayOfWeek
    Select-ComboTag $ui.CmbDom $config.Schedule.DayOfMonth
    Select-ComboTag $ui.CmbReboot $config.Reboot
    Select-ComboTag $ui.CmbLang $config.Language
    $ui.TxtTime.Text = $config.Schedule.Time
    $ui.ChkWake.IsChecked = [bool]$config.Schedule.WakeToRun
    $ui.RbActInstall.IsChecked = ($config.ScheduleAction -eq 'Install'); $ui.RbActNotify.IsChecked = ($config.ScheduleAction -eq 'Notify')
    foreach ($p in 'Critical', 'Important', 'Normal', 'Optional') { $ui["ChkPrio$p"].IsChecked = (@($config.AutoInstallPriorities) -contains $p) }
    $ui.RbVisible.IsChecked = ($config.Mode -eq 'Visible'); $ui.RbSilent.IsChecked = ($config.Mode -eq 'Silent')
    $ui.ChkParallel.IsChecked = [bool]$config.Parallel; $ui.ChkRestore.IsChecked = [bool]$config.RestorePoint
    foreach ($k in $sourceKeys) { $sourceBoxes[$k].IsChecked = [bool]$config.Sources.$k }
    $ui.ChkSelf.IsChecked = [bool]$config.SelfUpdate.Enabled; $ui.TxtRepo.Text = $config.SelfUpdate.Repo
    $ui.ExclChips.ItemsSource = @($config.ExcludedPackages)
    Update-SettingsUi
    $script:loading = $false
}

function Update-SettingsUi {
    $type = if ($ui.CmbSchedule.SelectedItem) { [string]$ui.CmbSchedule.SelectedItem.Tag } else { 'Manual' }
    $ui.PnlDay.Visibility = if ($type -in 'Weekly', 'BiWeekly') { 'Visible' } else { 'Collapsed' }
    $ui.PnlDom.Visibility = if ($type -eq 'Monthly') { 'Visible' } else { 'Collapsed' }
    $ui.PnlTime.Visibility = if ($type -eq 'Manual') { 'Collapsed' } else { 'Visible' }
    $ui.PnlAutoDetails.Visibility = $ui.PnlTime.Visibility
    $ui.PnlAutoPrio.Visibility = if ($ui.RbActInstall.IsChecked) { 'Visible' } else { 'Collapsed' }
    foreach ($k in 'WingetIncludeUnknown') { $sourceBoxes[$k].IsEnabled = [bool]$sourceBoxes['Winget'].IsChecked }
    foreach ($k in 'WindowsUpdateDrivers', 'MicrosoftUpdate') { $sourceBoxes[$k].IsEnabled = [bool]$sourceBoxes['WindowsUpdate'].IsChecked }
    $repo = $ui.TxtRepo.Text.Trim()
    $ui.ChkSelf.IsEnabled = [bool]$repo
    $ui.TxtSelfStatus.Text = if ($repo) { T 'set.selfReady' @($repo) } else { T 'set.selfMissing' }
}

function Save-Settings {
    if ($script:loading) { return }
    Update-SettingsUi
    try {
        $c = Get-Config
        $c.Schedule.Type = [string]$ui.CmbSchedule.SelectedItem.Tag
        $c.Schedule.DayOfWeek = [string]$ui.CmbDay.SelectedItem.Tag
        $c.Schedule.DayOfMonth = [int]$ui.CmbDom.SelectedItem.Tag
        $c.Schedule.Time = $ui.TxtTime.Text.Trim()
        $c.Schedule.WakeToRun = [bool]$ui.ChkWake.IsChecked
        $c.ScheduleAction = if ($ui.RbActNotify.IsChecked) { 'Notify' } else { 'Install' }
        $c.AutoInstallPriorities = @('Critical', 'Important', 'Normal', 'Optional' | Where-Object { $ui["ChkPrio$_"].IsChecked })
        $c.Mode = if ($ui.RbSilent.IsChecked) { 'Silent' } else { 'Visible' }
        $c.Parallel = [bool]$ui.ChkParallel.IsChecked
        $c.RestorePoint = [bool]$ui.ChkRestore.IsChecked
        $c.Reboot = [string]$ui.CmbReboot.SelectedItem.Tag
        foreach ($k in $sourceKeys) { $c.Sources.$k = [bool]$sourceBoxes[$k].IsChecked }
        $c.Language = [string]$ui.CmbLang.SelectedItem.Tag
        $c.SelfUpdate.Repo = $ui.TxtRepo.Text.Trim()
        $c.SelfUpdate.Enabled = [bool]$ui.ChkSelf.IsChecked -and [bool]$c.SelfUpdate.Repo
        Save-Config -Config $c
        $scheduleChanged = ($c.Schedule | ConvertTo-Json -Compress) -ne ($script:config.Schedule | ConvertTo-Json -Compress)
        if ($scheduleChanged) { Register-ScheduleTask -Config $c }
        $langChanged = $c.Language -ne $script:config.Language
        $script:config = $c
        if ($langChanged) { Import-I18n -Language $c.Language; Set-Texts; Show-Config; Update-RowTexts }
        Show-Summary
        $ui.TxtSaved.Foreground = Get-Brush '#30D158'; $ui.TxtSaved.Text = T 'set.saved'
    } catch {
        $ui.TxtSaved.Foreground = Get-Brush '#FF453A'
        $ui.TxtSaved.Text = T 'set.invalid' @($_.Exception.Message)
    }
}

function Set-Exclusion {
    <# Adds/removes an id pattern from the exclusion list and updates rows + chips immediately. #>
    param([string]$Id, [bool]$Exclude)
    if (-not $Id) { return }
    $c = Get-Config
    $list = [System.Collections.Generic.List[string]]@($c.ExcludedPackages)
    if ($Exclude) { if (-not $list.Contains($Id)) { $list.Add($Id) } } else { [void]$list.Remove($Id) }
    $c.ExcludedPackages = $list.ToArray()
    try { Save-Config -Config $c } catch { $ui.TxtSaved.Text = T 'set.invalid' @($_.Exception.Message); return }
    $script:config = $c
    $ui.ExclChips.ItemsSource = @($c.ExcludedPackages)
    foreach ($r in $rows) { Update-RowExclusion $r }
    $view.Refresh()
    Update-Counts
}

# ------------------------------------------------------------------ update list
function Test-IdExcluded { param([string]$Id) foreach ($p in @($config.ExcludedPackages)) { if ($Id -and $Id -like $p) { return $true } }; return $false }

function Update-RowExclusion { param($Row)
    if (-not $Row.CanExclude) { return }
    $Row.Excluded = Test-IdExcluded $Row.Id
    if ($Row.Excluded) { $Row.Selected = $false }
    $Row.ExcludeGlyph = if ($Row.Excluded) { [string][char]0xE7B3 } else { [string][char]0xED1A }
    $Row.ExcludeTip = if ($Row.Excluded) { T 'up.include' } else { T 'up.exclude' }
    Set-RowGroup $Row
}

function Set-RowGroup { param($Row)
    if ($Row.Excluded) { $Row.GroupLabel = T 'seg.excluded'; $Row.GroupRank = 4 }
    elseif ($Row.IsUpdate) { $Row.GroupLabel = T "prio.$($Row.Priority)"; $Row.GroupRank = $prioRank[$Row.Priority] }
    else { $Row.GroupLabel = T 'up.groupCurrent'; $Row.GroupRank = 5 }
}

function Set-RowState { param($Row, [string]$State)
    $Row.State = $State
    $Row.StateText = if ($State) { T "state.$State" } else { '' }
    $Row.StateBrush = if ($State -and $stateColors.ContainsKey($State)) { $stateColors[$State] } else { '#8E949F' }
}

function New-Row { param($Item, [bool]$IsUpdate)
    $r = New-Object Alerion.UpdateRow
    $r.Key = [string]$Item.Key; $r.Source = [string]$Item.Source; $r.Name = Resolve-Text ([string]$Item.Name)
    $r.Id = [string]$Item.Id; $r.From = [string]$Item.From; $r.To = [string]$Item.To; $r.Status = [string]$Item.Status
    $r.SourceLabel = T ('source.' + $r.Source)
    $r.Priority = if ($Item.PSObject.Properties.Name -contains 'Priority' -and $Item.Priority) { [string]$Item.Priority } else { 'Normal' }
    $r.PriorityLabel = T "prio.$($r.Priority)"; $r.PriorityBrush = $prioColors[$r.Priority]
    $r.IsCheck = ($Item.PSObject.Properties.Name -contains 'IsCheck') -and [bool]$Item.IsCheck
    $r.Major = ($Item.PSObject.Properties.Name -contains 'Major') -and [bool]$Item.Major
    $r.MajorLabel = T 'up.major'
    $r.IsUpdate = $IsUpdate
    $r.CanExclude = ($r.Source -in 'winget', 'choco', 'windows', 'gpu') -and $r.Id -and ($r.Id -notmatch '^(ARP|MSIX)\\')
    $r.Note = Resolve-Text ([string]$Item.Message)
    if ($r.IsCheck) { $r.To = ''; $r.Note = T 'msg.checkInstall' }
    if ($r.To -and $r.To -eq $r.Id) { $r.To = '' }   # Windows updates: the KB number is already shown as ID
    Update-RowExclusion $r
    if (-not $r.CanExclude) { $r.Excluded = $false; Set-RowGroup $r }
    if (-not $IsUpdate) { Set-RowState $r $(if ($r.Status -eq 'Failed') { 'Failed' } else { 'Current' }) }
    return $r
}

function Import-Scan {
    <# Loads state\last-scan.json into the list; keeps the user's selection when possible. #>
    $file = Join-Path $paths.StateDir 'last-scan.json'
    $previous = @{}; foreach ($r in $rows) { $previous[$r.Key] = $r.Selected }
    $hadRows = $rows.Count -gt 0
    $rows.Clear()
    $script:scanAt = $null
    if (-not (Test-Path $file)) { Update-Counts; return }
    try { $scan = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Update-Counts; return }
    $script:scanAt = [datetime]::Parse($scan.ScannedAt)
    $ids = @{}
    foreach ($i in @($scan.Items)) {
        if (-not $i) { continue }
        $isUpdate = $i.Status -eq 'Available' -or ($i.Status -eq 'Skipped' -and $i.Message -eq 'msg.excluded')
        $row = New-Row $i $isUpdate
        if ($row.IsUpdate -and -not $row.Excluded) {
            $row.Selected = if ($hadRows -and $previous.ContainsKey($row.Key)) { $previous[$row.Key] } else { $row.Priority -ne 'Optional' }
        }
        $rows.Add($row); if ($row.Id) { $ids[$row.Id] = $true }
    }
    foreach ($p in @($scan.Installed)) {
        if (-not $p -or -not $p.Id -or $ids.ContainsKey($p.Id)) { continue }
        $ids[$p.Id] = $true
        $item = [pscustomobject]@{ Key = "installed|$($p.Id)"; Source = $(if ($p.Source) { 'winget' } else { 'system' }); Name = $p.Name; Id = $p.Id; From = $p.Version; To = ''; Status = 'Info'; Message = '' }
        $rows.Add((New-Row $item $false))
    }
    Update-Counts
}

function Update-RowTexts { foreach ($r in $rows) { $r.SourceLabel = T ('source.' + $r.Source); $r.PriorityLabel = T "prio.$($r.Priority)"; $r.MajorLabel = T 'up.major'; Update-RowExclusion $r; if (-not $r.CanExclude) { Set-RowGroup $r }; if ($r.State) { Set-RowState $r $r.State } }; $view.Refresh() }

$view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('GroupRank', 'Ascending')))
$view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('Name', 'Ascending')))
$view.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription('GroupLabel')))
$view.Filter = [Predicate[object]]{
    param($r)
    $q = $script:search
    if ($q) {
        if ($r.Name.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and ([string]$r.Id).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        if ($script:segment -eq 'All') { return $true }   # search covers updates AND installed programs
    }
    switch ($script:segment) {
        'All'       { return $r.IsUpdate -and -not $r.Excluded }
        'Excluded'  { return $r.Excluded }
        'Installed' { return $true }
        default     { return $r.IsUpdate -and -not $r.Excluded -and $r.Priority -eq $script:segment }
    }
}

function Update-Counts {
    $upd = @($rows | Where-Object { $_.IsUpdate -and -not $_.Excluded -and -not $_.IsCheck })
    foreach ($p in 'Critical', 'Important', 'Normal', 'Optional') { $ui["TxtTile$p"].Text = [string]@($upd | Where-Object { $_.Priority -eq $p }).Count }
    $ui.Badge.Visibility = if ($upd.Count) { 'Visible' } else { 'Collapsed' }
    $ui.TxtBadge.Text = [string]$upd.Count
    $ui.Badge.Background = Get-Brush $(if (@($upd | Where-Object { $_.Priority -eq 'Critical' }).Count) { '#FF453A' } else { '#0A84FF' })
    $sel = @($rows | Where-Object { $_.Selected -and $_.Selectable })
    $ui.TxtSelected.Text = T 'up.selected' @($sel.Count)
    $ui.BtnInstallSelected.Content = T 'up.installSelected' @($sel.Count)
    $ui.BtnInstallSelected.IsEnabled = ($sel.Count -gt 0) -and -not $script:running
    $rec = @($rows | Where-Object { $_.Selectable -and $_.Priority -ne 'Optional' })
    $ui.BtnRecommended.Content = T 'ov.installRecommended' @(@($rec | Where-Object { -not $_.IsCheck }).Count)
    $ui.BtnRecommended.IsEnabled = ($rec.Count -gt 0) -and -not $script:running
    $ui.TxtUpdatesSub.Text = if ($script:scanAt) { T 'up.sub' @($upd.Count, (Format-When $script:scanAt)) } else { T 'up.notScanned' }
    $ui.TxtLastScan.Text = Format-When $script:scanAt
    Update-Hero
    Update-Empty
}

function Update-Empty {
    $visible = 0; foreach ($r in $view) { $visible++; break }
    $ui.EmptyPanel.Visibility = if ($visible) { 'Collapsed' } else { 'Visible' }
    if ($script:running -and $script:runMode -eq 'scan') { $ui.TxtEmpty.Text = T 'up.scanning'; $ui.EmptyGlyph.Text = [string][char]0xE895; $ui.EmptyGlyph.Foreground = Get-Brush '#0A84FF' }
    elseif ($script:search) { $ui.TxtEmpty.Text = T 'up.noMatch' @($script:search); $ui.EmptyGlyph.Text = [string][char]0xE721; $ui.EmptyGlyph.Foreground = Get-Brush '#8E949F' }
    elseif (-not $script:scanAt) { $ui.TxtEmpty.Text = T 'up.notScanned'; $ui.EmptyGlyph.Text = [string][char]0xE895; $ui.EmptyGlyph.Foreground = Get-Brush '#8E949F' }
    else { $ui.TxtEmpty.Text = T 'up.allCurrent'; $ui.EmptyGlyph.Text = [string][char]0xE73E; $ui.EmptyGlyph.Foreground = Get-Brush '#30D158' }
}

# ------------------------------------------------------------------ overview
function Update-Hero {
    $spin = $window.FindResource('Spin')
    if ($script:running) {
        $ui.TxtState.Text = if ($script:runMode -eq 'scan') { T 'ov.scanning' } else { T 'ov.running' }
        $ui.StateGlyph.Visibility = 'Collapsed'; $ui.StateCircle.Fill = Get-Brush '#0A84FF'; $ui.Spinner.Visibility = 'Visible'
        $spin.Begin($window, $true)
    } else {
        $spin.Stop($window); $ui.Spinner.Visibility = 'Collapsed'; $ui.StateGlyph.Visibility = 'Visible'
        $n = @($rows | Where-Object { $_.IsUpdate -and -not $_.Excluded -and -not $_.IsCheck }).Count
        $crit = @($rows | Where-Object { $_.IsUpdate -and -not $_.Excluded -and $_.Priority -eq 'Critical' }).Count
        if (-not $script:scanAt) { $ui.TxtState.Text = T 'ov.ready'; $col = '#8E949F'; $ui.StateGlyph.Text = [string][char]0xE895 }
        elseif ($n -eq 0) { $ui.TxtState.Text = T 'ov.allCurrent'; $col = '#30D158'; $ui.StateGlyph.Text = [string][char]0xE73E }
        else { $ui.TxtState.Text = T 'ov.available' @($n); $col = if ($crit) { '#FF453A' } else { '#0A84FF' }; $ui.StateGlyph.Text = [string][char]0xE896 }
        $ui.StateGlyph.Foreground = Get-Brush $col; $ui.StateCircle.Fill = Get-Brush $col
        $ui.TxtSub.Text = if ($crit) { T 'ov.criticalHint' @($crit) } else { T 'ov.lastScanLine' @(Format-When $script:scanAt) }
    }
    $ui.BtnScan.Visibility = if ($script:running) { 'Collapsed' } else { 'Visible' }
    $ui.BtnCancel.Visibility = if ($script:running -and $script:runMode -eq 'install') { 'Visible' } else { 'Collapsed' }
    $ui.ProgressPanel.Visibility = if ($script:running -and $script:runMode -eq 'install') { 'Visible' } else { 'Collapsed' }
}

function Show-Summary {
    $next = Get-NextRun
    $ui.TxtNext.Text = if ($config.Schedule.Type -eq 'Manual') { T 'ov.manualOnly' } elseif ($next) { $next.ToString('ddd, dd.MM.  HH:mm') } else { '-' }
    $last = Get-LastReport
    $ui.TxtLastRun.Text = if ($last -and -not $last.DryRun) { Format-When ([datetime]::Parse($last.EndedAt)) } else { T 'ov.never' }
    $ui.RebootBanner.Visibility = if (Test-PendingReboot) { 'Visible' } else { 'Collapsed' }
    Update-Counts
}

# ------------------------------------------------------------------ history
function Get-ReportFiles {
    @(Get-ChildItem $paths.ReportDir -Filter 'report-*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 60)
}

function Show-History {
    $items = foreach ($f in Get-ReportFiles) {
        try { $r = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $title = ([datetime]::Parse($r.EndedAt)).ToString('dd.MM.yyyy  HH:mm')
        $sub = if ($r.DryRun) { T 'hist.check' } else { T 'ov.resultLine' @($r.Counts.Updated, $r.Counts.Failed) }
        [pscustomobject]@{ Title = $title; Subtitle = $sub; Report = $r }
    }
    $ui.ReportList.ItemsSource = @($items)
    if (@($items).Count) { $ui.ReportList.SelectedIndex = 0 } else { Show-ReportGrid $null }
}

function Show-ReportGrid { param($Report)
    $ui.TxtHistoryEmpty.Text = T 'rep.none'
    $ui.TxtHistoryEmpty.Visibility = if ($Report) { 'Collapsed' } else { 'Visible' }
    $ui.HistoryCard.Visibility = if ($Report) { 'Visible' } else { 'Collapsed' }
    if (-not $Report) { $ui.TxtRepMeta.Text = ''; $ui.Grid.ItemsSource = $null; $ui.BtnHtml.IsEnabled = $false; return }
    $ui.BtnHtml.IsEnabled = [bool]($Report.PSObject.Properties.Name -contains 'HtmlPath' -and (Test-Path $Report.HtmlPath))
    $meta = T 'ov.resultLine' @($Report.Counts.Updated, $Report.Counts.Failed)
    if ($Report.RebootRequired) { $meta += '  -  ' + (T 'report.rebootTag') }
    $ui.TxtRepMeta.Text = $meta
    $order = @{ Failed = 0; Updated = 1; Available = 2; Triggered = 3; Skipped = 4; Info = 5 }
    $list = foreach ($i in (@($Report.Items) | Sort-Object { $order[[string]$_.Status] }, Source, Name)) {
        $note = Resolve-Text $i.Message
        if ($i.RebootRequired) { $note = (T 'report.rebootTag') + $(if ($note) { ' - ' + $note } else { '' }) }
        [pscustomobject]@{
            Source = T ('source.' + $i.Source); Name = Resolve-Text $i.Name; From = $i.From; To = $i.To
            StatusText = T ('status.' + $i.Status); StatusColor = $statusColors[[string]$i.Status]; Note = $note
        }
    }
    $ui.Grid.ItemsSource = @($list)
}

# ------------------------------------------------------------------ engine control
function Show-Page { param([string]$Name)
    foreach ($p in 'Overview', 'Updates', 'History', 'Settings') { $ui["Page$p"].Visibility = if ($p -eq $Name) { 'Visible' } else { 'Collapsed' } }
    if (-not $ui["Nav$Name"].IsChecked) { $ui["Nav$Name"].IsChecked = $true }
}

function Test-EngineRunning {
    $st = Get-Status
    return [bool]($st -and $st.Running -and (Get-Process -Id $st.Pid -ErrorAction SilentlyContinue))
}

function Start-Engine {
    param([ValidateSet('scan', 'install')][string]$Mode, [string[]]$Keys)
    if (Test-EngineRunning) { [System.Windows.MessageBox]::Show((T 'ov.alreadyRunning'), 'ALERION Update') | Out-Null; return }
    $engine = Join-Path $src 'UpdateEngine.ps1'
    $a = "--headless `"$PSHOME\powershell.exe`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$engine`" -FromGui"
    if ($Mode -eq 'scan') { $a += ' -Scan' }
    if ($Keys) {
        $sel = Join-Path $paths.StateDir 'selection.json'
        Write-AtomicFile -Path $sel -Content (ConvertTo-Json @($Keys) -Compress)
        $a += " -Selection `"$sel`""
    }
    [void](Start-Process -FilePath "$env:WINDIR\System32\conhost.exe" -ArgumentList $a -PassThru)
    $ui.LogList.Items.Clear()
    $script:running = $true; $script:runMode = $Mode; $script:wasRunning = $true
    Update-Counts
}

function Start-Install { param([object[]]$Selected)
    $keys = @($Selected | ForEach-Object { $_.Key })
    if (-not $keys.Count) { return }
    foreach ($r in $rows) { if ($r.IsUpdate) { Set-RowState $r '' } }
    foreach ($r in $Selected) { Set-RowState $r 'Pending' }
    Start-Engine -Mode install -Keys $keys
    Show-Page 'Overview'
}

function Confirm-Reboot {
    $r = [System.Windows.MessageBox]::Show((T 'dlg.rebootText'), (T 'dlg.rebootTitle'), 'YesNo', 'Question')
    if ($r -eq 'Yes') { Restart-Computer -Force }
}

# ------------------------------------------------------------------ polling
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(700)
$timer.Add_Tick({
    if ($showEvent.WaitOne(0)) { if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }; [void]$window.Activate() }
    $st = Get-Status
    if (-not $st) { return }
    $alive = $st.Running -and (Get-Process -Id $st.Pid -ErrorAction SilentlyContinue)
    if ($alive) {
        if (-not $script:running) { $script:running = $true; $script:wasRunning = $true; $script:runMode = [string]$st.Mode; Update-Counts }
        $ui.Progress.Value = [int]$st.Percent
        $ui.TxtPercent.Text = "$([int]$st.Percent) %"
        $ui.TxtCurrent.Text = [string]$st.Current
        $lines = @($st.Log)
        if ($lines.Count -ne $ui.LogList.Items.Count) {
            $ui.LogList.Items.Clear(); foreach ($l in $lines) { [void]$ui.LogList.Items.Add($l) }
            if ($ui.LogList.Items.Count) { $ui.LogList.ScrollIntoView($ui.LogList.Items[$ui.LogList.Items.Count - 1]) }
        }
        if ($st.PSObject.Properties.Name -contains 'Items' -and $st.Items) {
            $map = @{}; foreach ($p in $st.Items.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
            foreach ($r in $rows) { if ($map.ContainsKey($r.Key) -and $r.State -ne $map[$r.Key]) { Set-RowState $r $map[$r.Key] } }
        }
    } elseif ($script:wasRunning) {
        $finishedMode = $script:runMode
        $script:wasRunning = $false; $script:running = $false; $script:runMode = ''
        if ($finishedMode -eq 'scan') {
            Import-Scan; Show-Summary
        } else {
            Show-Summary; Show-History; Show-Page 'History'; [void]$window.Activate()
            $rep = Get-LastReport
            if ($rep -and $rep.RebootRequired -and -not $rep.DryRun -and $config.Reboot -eq 'Prompt') { Confirm-Reboot }
            Start-Engine -Mode scan   # refresh the list after installing
        }
    }
})

# ------------------------------------------------------------------ events
$ui.BtnClose.Add_Click({ $window.Close() })
$ui.BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$ui.BtnMax.Add_Click({ $window.WindowState = if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
$window.Add_StateChanged({ $window.BorderThickness = if ($window.WindowState -eq 'Maximized') { 7 } else { 0 } })
$ui.NavOverview.Add_Checked({ Show-Page 'Overview' })
$ui.NavUpdates.Add_Checked({ Show-Page 'Updates' })
$ui.NavHistory.Add_Checked({ Show-Page 'History'; Show-History })
$ui.NavSettings.Add_Checked({ Show-Page 'Settings'; $ui.TxtSaved.Text = '' })

$ui.BtnScan.Add_Click({ Start-Engine -Mode scan })
$ui.BtnCancel.Add_Click({ Request-Cancel; $ui.BtnCancel.IsEnabled = $false; $ui.TxtCurrent.Text = T 'ov.cancelling' })
$ui.BtnRecommended.Add_Click({ Start-Install @($rows | Where-Object { $_.Selectable -and $_.Priority -ne 'Optional' }) })
$ui.BtnInstallSelected.Add_Click({ Start-Install @($rows | Where-Object { $_.Selected -and $_.Selectable }) })
$ui.BtnSelectNone.Add_Click({ foreach ($r in $rows) { $r.Selected = $false }; Update-Counts })
$ui.BtnRestart.Add_Click({ Confirm-Reboot })
$ui.BtnToggleLog.Add_Click({
    $ui.LogList.Visibility = if ($ui.LogList.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
    $ui.BtnToggleLog.Content = if ($ui.LogList.Visibility -eq 'Visible') { T 'ov.hideLog' } else { T 'ov.showLog' }
})
foreach ($p in 'Critical', 'Important', 'Normal', 'Optional') {
    $ui["Tile$p"].Tag = $p
    $ui["Tile$p"].Add_Click({ param($s) $ui["Seg$($s.Tag)"].IsChecked = $true; Show-Page 'Updates' })
}
foreach ($seg in 'All', 'Critical', 'Important', 'Normal', 'Optional', 'Excluded', 'Installed') {
    $ui["Seg$seg"].Tag = $seg
    $ui["Seg$seg"].Add_Checked({ param($s) $script:segment = [string]$s.Tag; $view.Refresh(); Update-Empty })
}
$ui.TxtSearch.Add_TextChanged({
    $script:search = $ui.TxtSearch.Text.Trim()
    $ui.TxtSearchHint.Visibility = if ($ui.TxtSearch.Text) { 'Collapsed' } else { 'Visible' }
    $view.Refresh(); Update-Empty
})
# Clicks inside list rows / group headers / chips (template buttons are found by name)
$ui.UpdateList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $b = $e.OriginalSource
    if ($b -is [System.Windows.Controls.CheckBox]) { Update-Counts; return }
    if ($b.Name -eq 'ExcludeBtn') { $r = $b.DataContext; Set-Exclusion -Id $r.Id -Exclude (-not $r.Excluded); return }
    if ($b.Name -eq 'GroupSelect') {
        $group = [string]$b.Tag
        $members = @($view | Where-Object { $_.GroupLabel -eq $group -and $_.Selectable })
        $all = @($members | Where-Object { -not $_.Selected }).Count -eq 0
        foreach ($r in $members) { $r.Selected = -not $all }
        Update-Counts
    }
})
$ui.ExclChips.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e) if ($e.OriginalSource.Name -eq 'ChipRemove') { Set-Exclusion -Id ([string]$e.OriginalSource.Tag) -Exclude $false }
})
$ui.BtnExclAdd.Add_Click({ $id = $ui.TxtExclAdd.Text.Trim(); if ($id) { Set-Exclusion -Id $id -Exclude $true; $ui.TxtExclAdd.Text = '' } })
$ui.TxtExclAdd.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { $ui.BtnExclAdd.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } })
$ui.ReportList.Add_SelectionChanged({ if ($ui.ReportList.SelectedItem) { $script:shownReport = $ui.ReportList.SelectedItem.Report; Show-ReportGrid $script:shownReport } })
$ui.BtnLogs.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$($paths.LogDir)`"" })
$ui.BtnHtml.Add_Click({ $r = $script:shownReport; if ($r -and (Test-Path $r.HtmlPath)) { Start-Process $r.HtmlPath } })

# settings auto-save
foreach ($c in 'CmbSchedule', 'CmbDay', 'CmbDom', 'CmbReboot', 'CmbLang') { $ui[$c].Add_SelectionChanged({ Save-Settings }) }
foreach ($c in 'ChkWake', 'ChkParallel', 'ChkRestore', 'ChkSelf', 'ChkPrioCritical', 'ChkPrioImportant', 'ChkPrioNormal', 'ChkPrioOptional') { $ui[$c].Add_Click({ Save-Settings }) }
foreach ($c in 'RbActInstall', 'RbActNotify', 'RbVisible', 'RbSilent') { $ui[$c].Add_Checked({ Save-Settings }) }
foreach ($c in 'TxtTime', 'TxtRepo') {
    $ui[$c].Add_LostFocus({ Save-Settings })
    $ui[$c].Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Save-Settings } })
}
$ui.TxtRepo.Add_TextChanged({ Update-SettingsUi })

# keyboard: Ctrl+F search, F5 rescan, Esc clears search
$window.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'F' -and [System.Windows.Input.Keyboard]::Modifiers -eq 'Control') { Show-Page 'Updates'; [void]$ui.TxtSearch.Focus(); $e.Handled = $true }
    elseif ($e.Key -eq 'F5' -and -not $script:running) { Start-Engine -Mode scan; $e.Handled = $true }
    elseif ($e.Key -eq 'Escape' -and $ui.TxtSearch.IsKeyboardFocused) { $ui.TxtSearch.Text = '' }
})
$window.Add_Closed({ $timer.Stop(); try { $guiMutex.ReleaseMutex() } catch { } })

function Invoke-Snapshot {
    if ($Page -eq 'Settings') { $window.Height = 1700 }
    $window.WindowStartupLocation = 'Manual'; $window.Left = -4000; $window.Top = 0; $window.ShowInTaskbar = $false
    $window.Add_ContentRendered({
        Show-Page $Page; if ($Page -eq 'History') { Show-History }
        if ($Query) { $ui.TxtSearch.Text = $Query }
        $t = New-Object System.Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromMilliseconds(700)
        $t.Add_Tick({
            $t.Stop()
            $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$window.ActualWidth, [int]$window.ActualHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($window)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $fs = [IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
            $window.Close()
        }.GetNewClosure())
        $t.Start()
    })
    [void]$window.ShowDialog()
}

# ------------------------------------------------------------------ start
Initialize-Controls
Set-Texts
Show-Config
Import-Scan
Show-Summary
if (Test-EngineRunning) {
    $st = Get-Status; $script:running = $true; $script:wasRunning = $true; $script:runMode = [string]$st.Mode; Update-Counts
} elseif (-not $Snapshot -and (-not $script:scanAt -or ((Get-Date) - $script:scanAt).TotalMinutes -gt 30)) {
    Start-Engine -Mode scan   # fresh list on open
}
if ($Snapshot) { Invoke-Snapshot; return }
$timer.Start()
[void]$window.ShowDialog()
