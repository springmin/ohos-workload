// ArkUI login page for LoginAbility. Credentials are demo-only; the point is to prove a second
// ability renders its own ArkUI page without the MAUI host.
@Entry
@Component
struct Login {
  @State email: string = 'demo@springmin.com';
  @State password: string = 'demo';
  @State status: string = '';

  build() {
    Column({ space: 14 }) {
      Text('Reference LOB')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
      Text('LoginAbility · ArkUI page')
        .fontSize(14)
        .fontColor('#666666')

      Text('Email').fontSize(13).fontWeight(FontWeight.Medium)
      TextInput({ placeholder: 'name@company.com', text: this.email })
        .type(InputType.Email)
        .onChange((value: string) => { this.email = value; })

      Text('Password').fontSize(13).fontWeight(FontWeight.Medium)
      TextInput({ placeholder: 'password', text: this.password })
        .type(InputType.Password)
        .onChange((value: string) => { this.password = value; })

      Button('Sign in')
        .width('100%')
        .onClick(() => {
          if (this.email.indexOf('@') < 0 || this.password.length === 0) {
            this.status = 'Enter a valid email and password.';
          } else {
            this.status = 'Signed in as ' + this.email + ' (demo)';
          }
        })

      Text(this.status)
        .fontSize(13)
        .fontColor('#1B6EF3')

      Text('This page is rendered by a separate UIAbility (LoginAbility); it does not use the MAUI host.')
        .fontSize(12)
        .fontColor('#888888')
    }
    .width('100%')
    .padding(24)
    .alignItems(HorizontalAlign.Start)
  }
}
