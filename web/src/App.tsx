import { Route, Routes } from 'react-router-dom'
import { useAuthUser } from './data/auth'
import { SignInPage } from './ui/SignInPage'
import { UIDProvider } from './ui/UserContext'
import { TabBar } from './ui/components/TabBar'
import { CapturePage } from './ui/capture/CapturePage'
import { FeedPage } from './ui/feed/FeedPage'
import { FollowUpsPage } from './ui/followups/FollowUpsPage'
import { LogPage } from './ui/log/LogPage'
import { PeopleListPage } from './ui/people/PeopleListPage'
import { PersonPage } from './ui/people/PersonPage'
import { SettingsPage } from './ui/settings/SettingsPage'

function App() {
  const { user, ready } = useAuthUser()

  if (!ready) return null
  if (!user) return <SignInPage />

  return (
    <UIDProvider uid={user.uid}>
      <Routes>
        <Route path="/" element={<FeedPage />} />
        <Route path="/people" element={<PeopleListPage />} />
        <Route path="/people/:personID" element={<PersonPage />} />
        <Route path="/followups" element={<FollowUpsPage />} />
        <Route path="/log" element={<LogPage />} />
        <Route path="/capture" element={<CapturePage />} />
        <Route path="/settings" element={<SettingsPage />} />
      </Routes>
      <TabBar />
    </UIDProvider>
  )
}

export default App
